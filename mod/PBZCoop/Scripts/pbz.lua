-- PBZCoop game adapter for Phantom Blade Zero: what counts as an enemy, how health is read and changed, how a
-- player's moves are recognised and replayed, and how pickups are found. coop.lua calls these through api.game;
-- every function is optional, and missing ones simply switch that feature off.
--
-- Where the names come from (UE4SS SDK dump of build 26266538, see docs/RECON_NOTES.md):
--   enemies   APBZCharacter_NPC (BIsMonster), health in AttributeSetBase (UBasicAttributeSet.Health/Health_Max),
--             Kill(EPBZDieReason), hits through APBZCharacter::OnDamage
--   bosses    UPBZHUDLayout::RegisterBossHPBar(AActor*) plus FCodexEnemyRow.bIsBoss in DT_CodexEnemyDataTable
--   moves     GAS abilities (GA_Hun_Young_A, ..._AdvancedDash, ...) in the ASC's ActivatableAbilities
--   aggro     the hatred component's AddActorToHatredList
--   items     APBZPickupActor.ItemId, UPBZBackPackSubsystem::AddPropsToBackPack

return function(api)
    local log, valid, distance = api.log, api.valid, api.distance

    local PLAYER_CLASS_PREFIX = "BP_Renewal_Hun"   -- Hun's classes (young/adult); never treated as enemies
    local CODEX_TABLE = "/Game/PBZContent/DataTable/DT_CodexEnemyDataTable.DT_CodexEnemyDataTable"
    local DIE_DAMAGED, DIE_GAME_LOGIC = 1, 3        -- EPBZDieReason
    local SPAWN_ADJUST_ALWAYS = 2                   -- ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn
    local SCALE_MULTIPLY_WITH_ROOT = 1              -- ESpawnActorScaleMethod::MultiplyWithRoot
    local GHOST_AGGRO_CM = 2500                     -- enemies this close to the ghost also hate it
    local PICKUP_WATCH_CM = 500                     -- a vanished pickup this close to the local player was taken by them
    local GHOST_BUSY_S = 0.6                        -- after replaying a move, don't steer the ghost for this long

    local game = { commands = {} }
    local bosses = {}             -- actor address -> true, from RegisterBossHPBar
    local bossActors = {}         -- actor address -> the boss actor, for a second health bar (local co-op)
    local codexBoss = {}          -- class name (without _C) -> bIsBoss, filled lazily
    local syncing = false         -- true while the mod itself changes health, so OnDamage isn't re-reported
    local ghostBusyUntil = 0
    local busyGhosts = {}         -- with more than two players: ghost address -> the same, as each has moves of its own

    local function holdGhost(ghost, seconds)
        local till = os.clock() + (seconds or GHOST_BUSY_S)
        if api.coop and api.coop.net.party then
            busyGhosts[ghost:GetAddress()] = math.max(busyGhosts[ghost:GetAddress()] or 0, till)
        else
            ghostBusyUntil = math.max(ghostBusyUntil, till)
        end
    end

    local function className(actor)
        return actor:GetClass():GetFName():ToString()
    end

    local function lib(path)
        return StaticFindObject(path)
    end

    local function worldSubsystem(contextActor, classPath)
        local bl = lib("/Script/Engine.Default__SubsystemBlueprintLibrary")
        local cls = lib(classPath)
        if not valid(bl) or not valid(cls) then
            return nil
        end
        local s = bl:GetWorldSubsystem(contextActor, cls)
        return valid(s) and s or nil
    end

    local function codexRow(name)
        local dt = lib(CODEX_TABLE)
        if not valid(dt) then
            return nil
        end
        local ok, row = pcall(function() return dt:FindRow(name) end)
        return ok and row or nil
    end

    ------------------------------------------------------------------ enemies and health

    local function isEnemy(actor)
        if not valid(actor) then
            return false
        end
        local cn = className(actor)
        if cn:find(PLAYER_CLASS_PREFIX, 1, true) then
            return false
        end
        -- Not the NPCs who fight beside the players (the Fierce Axe swordsmen at the Dragon Pillar: held as the host's enemies
        -- on the guest, they couldn't be talked to and their fight never ended there), nor an enemy the game brings back
        -- again and again for a puzzle (the Bomber that opens the way to the Red House: killed for good on the guest, the
        -- way stayed shut). Each world has its own, as alone.
        if cn:lower():find("npchelper", 1, true) or cn:find("Respawn_C$") then     -- (spelt NpcHelper and NPChelper)
            return false
        end
        local ok, monster = pcall(function() return actor.BIsMonster end)
        return (ok and monster == true) or cn:find("^BP_Monster") ~= nil
    end
    game.isEnemy = isEnemy

    -- Facts about an actor that never change, by address, so they're only worked out once: these run for every enemy
    -- many times a second. Addresses get reused, so they're cleared on a map change and every ACTOR_FACTS_S anyway
    -- (local co-op has no map watch, and streaming reuses addresses on one map).
    local ACTOR_FACTS_S = 30
    local knownEnemy, knownBoss, spawnerNames, factsAt = {}, {}, {}, os.clock()
    function game.forgetActors()
        knownEnemy, knownBoss, spawnerNames, factsAt = {}, {}, {}, os.clock()
    end

    -- Everything the net loop reads about a character, in one call. Through UE4SS that's 30-100 us a property and an object
    -- made for each; link.read (native/lua_link.hpp) takes it straight from memory, at offsets the game's reflection gives
    -- once. Each class of character is compared with a normal read first: one difference, and reads go through UE4SS again.
    local link = api.link
    local ATTRIBUTE_VALUE = 12      -- FGameplayAttributeData: vtable, BaseValue, then CurrentValue
    local layout = nil              -- true: link.read can be used; false: it can't; nil: not tried yet
    local layoutChecked = {}        -- class name -> true once link.read gave the same as a normal read

    local function readSlowly(actor)
        local l, r = actor:K2_GetActorLocation(), actor:K2_GetActorRotation()
        local cmc, set = actor.CharacterMovement, actor.AttributeSetBase
        local v = cmc.Velocity
        return l.X, l.Y, l.Z, r.Yaw, v.X, v.Y, v.Z, cmc.MovementMode, set.Health.CurrentValue, set.Health_Max.CurrentValue,
            set.Shachi.CurrentValue
    end

    local function checkLayout(actor, addr)
        local x, y, z, yaw, vx, vy, vz, mode, hp, maxhp, posture = link.read(addr)
        local ok, X, Y, Z, Yaw, VX, VY, VZ, Mode, Hp, MaxHp, Posture = pcall(readSlowly, actor)
        if x == nil or not ok then
            return                  -- attached to something, say: no verdict
        end
        local function same(a, b)
            return type(b) == "number" and math.abs(a - b) <= 0.5
        end
        if same(x, X) and same(y, Y) and same(z, Z) and same((yaw - Yaw + 180) % 360, 180) and same(vx, VX) and same(vy, VY)
            and same(vz, VZ) and mode == Mode and same(hp, Hp) and same(maxhp, MaxHp) and same(posture, Posture) then
            return true
        end
        layout = false
        log(string.format("Fast reads off: %s read %.1f %.1f %.1f yaw %.1f hp %.1f, the game says %.1f %.1f %.1f yaw %.1f hp %.1f.",
            className(actor), x, y, z, yaw, hp, X, Y, Z, Yaw, Hp))
    end

    local function learnLayout(actor)
        layout = false
        if not (link and link.layout and link.read) then
            return
        end
        local function offset(obj, name)
            return obj:Reflection():GetProperty(name):GetOffset_Internal()
        end
        local ok, err = pcall(function()
            local root, cmc, set = actor.RootComponent, actor.CharacterMovement, actor.AttributeSetBase
            link.layout(offset(actor, "RootComponent"), offset(root, "RelativeLocation"), offset(root, "RelativeRotation"),
                offset(root, "AttachParent"), offset(actor, "CharacterMovement"), offset(cmc, "Velocity"),
                offset(cmc, "MovementMode"), offset(actor, "AttributeSetBase"), offset(set, "Health") + ATTRIBUTE_VALUE,
                offset(set, "Health_Max") + ATTRIBUTE_VALUE, offset(set, "Shachi") + ATTRIBUTE_VALUE)
        end)
        if ok then
            layout = true
            layoutChecked[className(actor)] = checkLayout(actor, actor:GetAddress())
            log("Fast reads " .. (layout and "on." or "off."))
        else
            log("Fast reads off: " .. tostring(err))
        end
    end

    -- A stale actor (e.g. one replaced by a respawn) can hand back an object instead of a number.
    local function askedSlowly(ok, x, y, z, yaw, vx, vy, vz, mode, hp, maxhp, posture)
        if ok and type(x) == "number" and type(hp) == "number" and type(maxhp) == "number" then
            return x, y, z, yaw, vx, vy, vz, mode, hp, maxhp, posture
        end
    end

    -- x, y, z, yaw, vx, vy, vz, movement mode, health, max health, posture; nothing at all from a stale actor.
    function game.read(actor, addr)
        if layout then
            local x, y, z, yaw, vx, vy, vz, mode, hp, maxhp, posture = link.read(addr)
            if x then
                return x, y, z, yaw, vx, vy, vz, mode, hp, maxhp, posture
            end
        elseif layout == nil then
            learnLayout(actor)
        end
        return askedSlowly(pcall(readSlowly, actor))
    end

    local function locationOf(actor)
        return actor:K2_GetActorLocation()
    end

    -- x, y, z, or nothing.
    function game.where(actor, addr)
        if layout then
            local x, y, z = link.read(addr)
            if x then
                return x, y, z
            end
        end
        if valid(actor) then
            local ok, l = pcall(locationOf, actor)
            if ok and l.X ~= nil then
                return l.X, l.Y, l.Z
            end
        end
    end

    -- Where a controller keeps its pawn, once it's been seen to agree with the pawn it has. False: it can't be read directly.
    local pawnAt = nil
    function game.pawnOffset(pc, pcAddr, pawnAddr)
        if pawnAt == nil then
            pawnAt = false
            if link and link.pointer then
                pcall(function()
                    local at = pc:Reflection():GetProperty("Pawn"):GetOffset_Internal()
                    if link.pointer(pcAddr, at) == pawnAddr then
                        pawnAt = at
                    end
                end)
            end
        end
        return pawnAt
    end

    -- A search of all objects is 1-3 ms: never two in one frame.
    local SEARCH_APART_S = 0.03
    local searchedAt = -1e9

    local function searched()
        searchedAt = link and link.now() or 0
    end

    local function maySearch()
        return not link or link.now() - searchedAt >= SEARCH_APART_S
    end

    -- Enemy ids that are the same on both PCs. Runtime actor names are not (the same placed character was
    -- ..._2147476826 in one session and ..._2147477757 in the next), but enemies come from level-placed
    -- AISpawners whose designer SpawnerID ("ZuoShangyoung_Seq003") is stable, so an enemy made by a spawner is
    -- "sp:<SpawnerID>". Most spawners have no SpawnerID (174 of 180 in Xigu): every enemy of theirs was "sp:None", so
    -- one death read as all of them. Their level actor names (..._UAID_...) are the same on both PCs, so those stand
    -- in. Others keep their actor name, and coop.lua falls back to class + position matching.
    -- A few spawners per call, so the scan never costs a frame; force reads them all at once. The spawners themselves only
    -- come and go with the level, so the list is kept between passes unless an enemy turned up without an id, and a spawner's
    -- id is read once. What it has spawned is read with link.pointer: spawners outnumber enemies, and this ran 240 times a second.
    local ID_SLICE = 24
    local ID_PASS_S = 1.0
    local ID_LIST_S = 4.0
    local spawnerIds = {}
    local spawnerList, spawnerAddrs, spawnerAt, passSeen, passAt, listAt = {}, {}, 1, {}, -1e9, -1e9
    local idMissing = false         -- an enemy had no id: its spawner may be new
    local actorNames = {}           -- address -> actor name, for the enemies without a spawner, kept for a pass
    local spawnedOffset = nil       -- where a spawner keeps SpawnedAI; false: it can't be read directly

    local function spawnerName(s, addr)
        local name = spawnerNames[addr]
        if name == nil then
            local id = s.SpawnerID:ToString()
            name = "sp:" .. (id ~= "None" and id or s:GetFName():ToString())
            spawnerNames[addr] = name
        end
        return name
    end

    -- Once, on a spawner that has something to compare with.
    local function learnSpawned(s, addr, a)
        spawnedOffset = false
        if link and link.pointer then
            pcall(function()
                local at = s:Reflection():GetProperty("SpawnedAI"):GetOffset_Internal()
                if link.pointer(addr, at) == a:GetAddress() then
                    spawnedOffset = at
                end
            end)
        end
    end

    local function readSpawnerSlowly(s, addr, into)
        local a = s.SpawnedAI
        if valid(a) then
            if spawnedOffset == nil then
                learnSpawned(s, addr, a)
            end
            local aiAddr = a:GetAddress()
            local name = spawnerName(s, addr)
            spawnerIds[aiAddr] = name
            into[aiAddr] = name
        end
    end

    local function readSpawner(i, into)
        local s, addr = spawnerList[i], spawnerAddrs[i]
        if addr == nil then
            -- From a list up to a few seconds old: it may be gone, and a throw here would stop every pass after it.
            addr = valid(s) and s:GetAddress() or 0
            spawnerAddrs[i] = addr
        end
        if addr == 0 then
            return
        end
        if spawnedOffset then
            local aiAddr = link.pointer(addr, spawnedOffset)
            if aiAddr ~= 0 and spawnerNames[addr] then
                spawnerIds[aiAddr] = spawnerNames[addr]
                into[aiAddr] = spawnerNames[addr]
                return
            elseif aiAddr == 0 then
                return
            end
        end
        if valid(s) then
            pcall(readSpawnerSlowly, s, addr, into)
        end
    end

    local function newSpawnerList(now)
        spawnerList, spawnerAddrs, listAt = FindAllOf("AISpawner") or {}, {}, now
        idMissing = false
    end

    function game.refreshEnemyIds(force)
        if force then
            newSpawnerList(os.clock())
            spawnerAt, passSeen = 1, {}
        elseif spawnerAt > #spawnerList then
            local now = os.clock()
            if now - passAt < ID_PASS_S then
                return
            end
            passAt = now
            spawnerIds = next(passSeen) and passSeen or spawnerIds    -- what the last pass found: enemies gone are forgotten
            actorNames = {}
            if (idMissing or now - listAt >= ID_LIST_S) and maySearch() then
                newSpawnerList(now)
                searched()
            end
            spawnerAt, passSeen = 1, {}
        end
        local stop = force and #spawnerList or math.min(spawnerAt + ID_SLICE - 1, #spawnerList)
        for i = spawnerAt, stop do
            readSpawner(i, passSeen)
        end
        spawnerAt = stop + 1
    end

    -- Ghost twins (twins.lua): an id both PCs give their copy, "tw<n>:" and the original's id. A twin is never the boss of a
    -- fight to the mod: its death ends no fight and marks nothing beaten, and the story goes by the original's alone.
    -- ids: actor address -> twin id. names: address -> the twin actor's name: an address the game gives a new enemy
    -- after the twin is gone isn't the twin's (it was taken for it: no twin, no fight).
    local twin = { ids = {}, names = {} }
    function game.markTwin(addr, id, name)
        twin.ids[addr], twin.names[addr] = id, name
    end
    function game.forgetTwin(addr)
        twin.ids[addr], twin.names[addr] = nil, nil
    end
    -- actor: the one at that address now, when the caller has it, to tell a new actor there from the twin.
    function twin.at(addr, actor)
        local id = twin.ids[addr]
        if id and actor and twin.names[addr] then
            local ok, name = pcall(function() return actor:GetFName():ToString() end)
            if ok and name ~= twin.names[addr] then
                twin.ids[addr], twin.names[addr] = nil, nil
                return nil
            end
        end
        return id
    end
    function game.twinId(addr, actor)
        return twin.at(addr, actor)
    end

    -- addr: the actor's address, when the caller has it.
    function game.enemyId(actor, addr)
        addr = addr or actor:GetAddress()
        local id = twin.at(addr, actor) or spawnerIds[addr]
        if id then
            return id
        end
        idMissing = true
        id = actorNames[addr]
        if id == nil then
            id = actor:GetFName():ToString()
            actorNames[addr] = id
        end
        return id
    end

    -- Guest copies of the host's enemies: their own AI stays out of it (puppets.lua). The game starts a stopped AI again
    -- by itself, so this is asked again and again: pass the brain it returned last time.
    -- Each link checked, every time: one not possessed yet (or any more) has no controller, and a call on nothing is a
    -- crash pcall doesn't catch. Not kept between calls either: a brain kept by its address could be something else's.
    function game.brainOf(actor)
        if not valid(actor) then
            return nil
        end
        local c = actor:GetController()
        if not valid(c) then
            return nil
        end
        local b = c.BrainComponent
        return valid(b) and b or nil
    end

    function game.stopAI(actor)
        local brain = nil
        pcall(function()
            brain = game.brainOf(actor)
            if brain and brain:IsRunning() then
                brain:StopLogic("PhantomPact")
            end
        end)
        return brain
    end

    function game.startAI(actor)
        pcall(function()
            local brain = game.brainOf(actor)
            if brain then
                brain:RestartLogic()
            end
        end)
    end

    -- Out of the way on this PC, and back: coop.lua, for an enemy the host's world doesn't have. home: where it stands, given
    -- with on and again with off. Hidden isn't enough: a live enemy within some 10-30 m keeps a bell from being rung, hidden or
    -- not, collision or not (tried on a real bell, 11-05), and a guest whose save is behind the host's had the host's long-dead
    -- enemies standing at bells, out of sight: "why can't I ring the bell in my friend's game?". So it waits 500 m up, held
    -- there, and comes back to the same spot.
    game.ASIDE_UP_CM = 50000
    function game.stepAside(actor, on, home)
        pcall(function()
            actor:SetActorHiddenInGame(on)
            actor:SetActorEnableCollision(not on)
        end)
        if not home then
            return
        end
        pcall(function()
            local cmc = actor.CharacterMovement
            if on then
                if valid(cmc) then
                    cmc:SetMovementMode(0, 0)       -- (MOVE_None: no falling from up there)
                end
                actor:K2_SetActorLocation({ X = home.X, Y = home.Y, Z = home.Z + game.ASIDE_UP_CM }, false, {}, true)
            else
                actor:K2_SetActorLocation({ X = home.X, Y = home.Y, Z = home.Z }, false, {}, true)
                if valid(cmc) then
                    cmc:SetMovementMode(1, 0)       -- (MOVE_Walking)
                end
            end
        end)
    end

    function game.enemyClass(actor)
        return className(actor)
    end

    -- spawner <SpawnerID|list>: make a level AISpawner spawn its enemy, as the game's encounter scripts do.
    game.commands.spawner = function(id)
        for _, s in ipairs(FindAllOf("AISpawner") or {}) do
            local sid = "?"
            pcall(function() sid = s.SpawnerID:ToString() end)
            if id == nil or id == "" or id == "list" then
                log("  spawner " .. sid)
            elseif sid == id then
                local ok, err = pcall(function() s:ClaimSeqSpawn(false, true, true) end)
                log("ClaimSeqSpawn(" .. sid .. "): " .. tostring(ok) .. " " .. tostring(err))
                return
            end
        end
    end

    -- A boss is beaten in a world when its spawner says so: one that never brings its enemy back turns ShouldSpawn off as the
    -- enemy dies and saves that in the world's list of spawners, which goes into the save and which IsShouldToSpawn reads back.
    -- The game starts that from a mark on the dying body, and a copy killed for the partner's kill dies without it: the boss
    -- was beaten in one save only, and after a load one player had it back and fought it alone.
    local SPAWNER_BP = "/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C"
    -- Inside one batch of events (coop.lua's processEvents, one frame): the map's spawners searched once, by id, and let
    -- go at its end. Nothing's kept past the frame: a batch never ended (an error between its ends) is let go once it's
    -- older than a frame could be, not used again by the next turn that asks. (A field, not a local: this function is at
    -- Lua's 200 locals.)
    function game.beginBatch()
        game.batch = { at = os.clock() }
    end
    function game.endBatch()
        game.batch = nil
    end

    local function spawnerOf(enemyId)
        local id = enemyId and enemyId:match("^sp:(.+)$")
        local batch = game.batch
        if batch and os.clock() - (batch.at or -1e9) > 0.5 then
            game.batch, batch = nil, nil
        end
        if id and batch then
            if not batch.spawners then
                batch.spawners = {}
                for _, s in ipairs(FindAllOf("AISpawner") or {}) do
                    local sid = nil
                    pcall(function() sid = s.SpawnerID:ToString() end)
                    local key = sid
                    if sid == "None" then
                        pcall(function() key = s:GetFName():ToString() end)
                    end
                    -- (The first valid one, as the search below takes: one going with its level, still listed, hid the
                    -- live one of the same id.)
                    if key and batch.spawners[key] == nil and valid(s) then
                        batch.spawners[key] = s
                    end
                end
            end
            local s = batch.spawners[id]
            return valid(s) and s or nil
        end
        for _, s in ipairs(id and FindAllOf("AISpawner") or {}) do
            local sid = nil
            pcall(function() sid = s.SpawnerID:ToString() end)
            -- (A spawner with no designer id goes by its level name: see readSpawner.)
            if valid(s) and (sid == id or (sid == "None" and s:GetFName():ToString() == id)) then
                return s
            end
        end
        return nil
    end

    -- The game's own step for a spawner whose enemy has died: what it does is up to the spawner. (Its flags are its blueprint's,
    -- so only asked of one: UE4SS answers a property by name from whatever class has it.)
    function game.markBeaten(enemyId)
        local s = spawnerOf(enemyId)
        local ok, once = pcall(function()
            return s:IsA(StaticFindObject(SPAWNER_BP)) and s.SetShouldNotSpawnAfterDead == true
        end)
        if not (ok and once) then
            return false
        end
        local beaten = game.isBeaten(enemyId)
        local saved = pcall(function()
            s.ShouldSpawn = false
            s:Save()
        end)
        if saved and beaten == false then
            log("Beaten in this world too: " .. enemyId .. ".")
            game.wroteBeaten = game.wroteBeaten or {}
            game.wroteBeaten[enemyId] = true        -- (this session's own write: see unmarkBeaten)
        end
        return saved
    end

    -- A boss written beaten at a fall it got up from (Xiaoxue's, in the same fight): alive in this world's record again.
    -- Only a write of this session's markBeaten is undone, never the save's own.
    function game.unmarkBeaten(enemyId)
        if not (game.wroteBeaten and game.wroteBeaten[enemyId]) then
            return false
        end
        local s = spawnerOf(enemyId)
        local ok = s ~= nil and pcall(function()
            s.ShouldSpawn = true
            s:Save()
        end)
        if ok then
            game.wroteBeaten[enemyId] = nil
            log("Up again after its fall: not beaten in this world after all: " .. enemyId .. ".")
        end
        return ok
    end

    -- True when this world has the boss beaten, false when it hasn't, nil when its spawner isn't loaded here.
    function game.isBeaten(enemyId)
        local s = spawnerOf(enemyId)
        if not s then
            return nil
        end
        local ok, should = pcall(function() return s:IsShouldToSpawn() end)
        if not ok or type(should) ~= "boolean" then
            return nil
        end
        return not should
    end

    -- The other player's boss, on this PC too: a boss only spawns on the PC whose player started the fight. Returns
    -- its spawner's location, or nil for an enemy that doesn't come from a named spawner, and true if it was beaten in this
    -- save and turned back for the fight (the caller puts it back: see bringBack). revive false: one this save has beaten
    -- stays so.
    -- A boss of phases, a spawner each, by its name without the phase and the sequence: nil for one that isn't. (Also
    -- "_P<n>..." and "_Seqs...": the forest's YuCong is YuCong_P1, YuCong_Seqs028, YuCong_P3_1/2/3, YuCong_P3_Yuu.)
    function game.phaseGroup(sid)
        if type(sid) ~= "string" then
            return nil
        end
        sid = sid:gsub("^sp:", "")
        if not (sid:find("_Seq", 1, true) or sid:find("P%d+$") or sid:find("_P%d")) then
            return nil
        end
        return (sid:gsub("_Seq.*$", ""):gsub("_P%d.*$", ""):gsub("P%d+$", ""))
    end

    -- A boss's later phase (P2 on): HookManP2_Seq023, ChangHongP2_Seq107, MuXiaoKuiP2_Seq046new, LeiDangP2, YuCong_P3_1.
    -- Not a "_Seq" alone: most story bosses spawn from a sequence (ChiLian_Seq034, the forest's last), and are one phase.
    function game.isLaterPhase(enemyId)
        local id = type(enemyId) == "string" and enemyId:gsub("^sp:", "") or ""
        return id:find("P[2-9]%f[^%d]") ~= nil or id:find("_P[2-9]") ~= nil
    end

    function game.spawnBoss(enemyId, revive)
        local id = enemyId:match("^sp:(.+)$")
        -- (A boss of phases, a spawner each: HookManP1_Seq022 / HookManP2_Seq023, but also ChangHong_Seq106 /
        -- ChangHongP2_Seq107, MuXiaoKui_Seq045 / MuXiaoKuiP2_Seq046new, LeiDang_Seq123-3 / LeiDangP2: one boss by its name
        -- without the phase and the sequence. Another phase alive here is that fight already: spawned beside it, both
        -- phases stood there, two bars up.)
        local phaseGroup = game.phaseGroup
        local group = phaseGroup(id)
        if group and group ~= "" then
            for _, s in ipairs(FindAllOf("AISpawner") or {}) do
                local sid = nil
                pcall(function() sid = s.SpawnerID:ToString() end)
                if sid and sid ~= id and phaseGroup(sid) == group then
                    local live = nil
                    pcall(function()
                        if valid(s.SpawnedAI) and not game.isDead(s.SpawnedAI) then
                            live = s.SpawnedAI:K2_GetActorLocation()
                        end
                    end)
                    if live then
                        log("Boss " .. enemyId .. ": another phase of it (" .. sid .. ") is here already, not spawned.")
                        return { X = live.X, Y = live.Y, Z = live.Z }, false
                    end
                end
            end
        end
        for _, s in ipairs(id and FindAllOf("AISpawner") or {}) do
            local sid = nil
            pcall(function() sid = s.SpawnerID:ToString() end)
            -- (A spawner with no designer id goes by its level name: see readSpawner.)
            if sid == id or (sid == "None" and s:GetFName():ToString() == id) then
                local at = s:K2_GetActorLocation()
                local alive = false
                pcall(function() alive = valid(s.SpawnedAI) and not game.isDead(s.SpawnedAI) end)
                -- (Or alive by another way in: a story boss comes from its fight's scene, not as this spawner's own enemy.
                -- Spawned again here, two stood in the arena: one paired with the partner's, one on its own, and the kill of
                -- the wrong one reached nobody, the partner's left at full health.)
                local other = not alive and game.liveBossesWithId(enemyId)[1]
                if other then
                    local l = other:K2_GetActorLocation()
                    return { X = l.X, Y = l.Y, Z = l.Z }, false
                end
                local beaten = not alive and game.isBeaten(enemyId)
                if beaten and revive == false then
                    return { X = at.X, Y = at.Y, Z = at.Z }
                end
                if beaten then
                    -- Beaten here and not in the partner's world, whose fight it is: back for it, or they'd fight it unseen.
                    pcall(function()
                        s.ShouldSpawn = true
                        if s:IsA(StaticFindObject(SPAWNER_BP)) then
                            s:Save()
                        end
                    end)
                    log("Beaten here but not in the other player's world: " .. enemyId .. " is back for their fight.")
                end
                local spawned = nil         -- the one spawned here: { addr, fname, class }, read at once (no object kept)
                if not alive then
                    local ok, err = pcall(function() s:ClaimSeqSpawn(false, true, true) end)
                    if not ok then
                        log("Couldn't spawn " .. id .. ": " .. tostring(err))
                    end
                    pcall(function()
                        local a = s.SpawnedAI
                        if ok and valid(a) then
                            spawned = { addr = a:GetAddress(), fname = a:GetFName():ToString(),
                                class = a:GetClass():GetFName():ToString() }
                        end
                    end)
                    -- (Not in yet: its spawner is kept, for dropExtraBoss to find it there later. With nothing kept, no watch
                    -- was made, and the scene's own boss came in beside it, a bar each.)
                    if ok and not spawned then
                        spawned = { spawner = id }
                    end
                end
                return { X = at.X, Y = at.Y, Z = at.Z }, beaten, spawned
            end
        end
        return nil
    end

    -- The live bosses in this world that go by this id (a story boss's scene can bring one in that isn't its spawner's own).
    function game.liveBossesWithId(enemyId)
        local out = {}
        for _, a in pairs(game.listEnemies(true) or {}) do
            if valid(a) and not game.isDead(a) and game.enemyId(a) == enemyId and game.isBoss(a) then
                out[#out + 1] = a
            end
        end
        return out
    end

    -- A boss spawned here for the partner's fight (spawnBoss's { addr, fname, class }) and then another of its kind from
    -- this world's own fight scene: the one spawned for the partner goes, with no death (a death would run its story), and
    -- the scene's is the one paired. True if it went; false while it's the only one; nil once it's gone or dead anyway.
    -- (A fresh look, once a second at most while a watch lasts: the cached list missed the one spawned a moment before, the
    -- watch was let go at its first look, and with this world's own scene's boss in too, two stood there with a bar each,
    -- the unpaired one full for good; a report on 1.6.9.)
    -- (name: the boss's id. Another boss going by it is the scene's too, of another class or not.)
    function game.dropExtraBoss(mine, name)
        if not mine.addr and mine.spawner then
            for _, s in ipairs(FindAllOf("AISpawner") or {}) do
                local sid = nil
                pcall(function() sid = s.SpawnerID:ToString() end)
                if sid == mine.spawner or (sid == "None" and s:GetFName():ToString() == mine.spawner) then
                    pcall(function()
                        local a = s.SpawnedAI
                        if valid(a) then
                            mine.addr, mine.fname = a:GetAddress(), a:GetFName():ToString()
                            mine.class = a:GetClass():GetFName():ToString()
                        end
                    end)
                    break
                end
            end
            if not mine.addr then
                return false        -- (still not in: kept watching)
            end
        end
        local ours, other = nil, false
        for _, a in pairs(game.listEnemies(true) or {}) do
            if valid(a) and not game.isDead(a) then
                local addr = a:GetAddress()
                local ok, cls = pcall(function() return a:GetClass():GetFName():ToString() end)
                local sameId = name ~= nil and game.enemyId(a) == name
                if ok and (cls == mine.class or sameId) then
                    if addr == mine.addr and a:GetFName():ToString() == mine.fname then
                        ours = a
                    elseif not twin.at(addr, a) and game.isBoss(a, addr) then
                        -- (Another boss of its kind, not its ghost twin: with 5-6 players the twin is the same class, and
                        -- taken for the scene's boss, the boss being fought was taken away.)
                        other = true
                    end
                end
            end
        end
        if not ours then
            return nil
        end
        if not other then
            return false
        end
        pcall(game.hideBossBar, ours)
        pcall(function() ours:K2_DestroyActor() end)
        return true
    end

    -- One spawned here for the partner's fight (spawnBoss's { addr, fname, class }), that fight over without it dying (the
    -- partner walked out, died or rested): it goes, with no death, as one the scene replaced does. Left, it stood with its
    -- own AI by the arena, the bells near it said "in combat", and a host who met it later fought a boss outside any
    -- encounter. True if it went.
    function game.dropStandIn(mine)
        for _, a in pairs(game.listEnemies() or {}) do
            if valid(a) and not game.isDead(a) and a:GetAddress() == mine.addr then
                local ok, fname = pcall(function() return a:GetFName():ToString() end)
                if ok and fname == mine.fname then
                    pcall(game.hideBossBar, a)
                    pcall(function() a:K2_DestroyActor() end)
                    return true
                end
            end
        end
        return false
    end

    -- The host's enemy, in this world too: kills last for good in a save, so a guest who has played further has the early
    -- enemies long dead and saw the host fight thin air, with nothing there to hit them either. Its spawner here brings it back
    -- as the game's encounter scripts would. Returns true if it was asked to, and whether this save had it dead (its record is
    -- turned back then, so the spawner will spawn: putBack writes it dead again once this copy is done).
    function game.bringBack(enemyId)
        local s = spawnerOf(enemyId)
        if not s then
            return false
        end
        local alive = false
        pcall(function() alive = valid(s.SpawnedAI) and not game.isDead(s.SpawnedAI) end)
        if alive then
            return false
        end
        local dead = game.isBeaten(enemyId) == true
        if dead then
            -- (Owed from now: written dead again at the session's end, or later if its spawner isn't there then.)
            local owed = game.owed.load()
            if not owed[enemyId] then
                owed[enemyId] = true
                pcall(game.owed.save)
            end
            pcall(function()
                s.ShouldSpawn = true
                if s:IsA(StaticFindObject(SPAWNER_BP)) then
                    s:Save()
                end
            end)
        end
        local ok = pcall(function() s:ClaimSeqSpawn(false, true, true) end)
        if not ok and dead then
            game.putBack(enemyId)           -- (nothing came: the save keeps it dead)
        end
        return ok, dead
    end

    -- Records bringBack turned back that aren't dead again yet: one whose spawner had streamed out when the session ended
    -- left that enemy alive in this save for good. Each is written dead again the next time its spawner is loaded
    -- (game.owed.retry), and only then dropped. In memory only: a list kept in a file would follow the player into
    -- another save, and kill there an enemy that save has alive.
    game.owed = { ids = {} }
    function game.owed.load()
        return game.owed.ids
    end
    function game.owed.save()
    end

    -- Spawners bringBack turned back, as this save had them: dead. One id, or a set of ids (id -> true) in one look
    -- through the spawners. Those not loaded now stay owed (game.owed).
    function game.putBack(ids)
        if type(ids) == "string" then
            ids = { [ids] = true }
        end
        local n = 0
        local found = {}
        for _, s in ipairs(next(ids) and FindAllOf("AISpawner") or {}) do
            pcall(function()
                if not valid(s) then
                    return
                end
                local sid = s.SpawnerID:ToString()
                local name = "sp:" .. (sid ~= "None" and sid or s:GetFName():ToString())
                if ids[name] then
                    s.ShouldSpawn = false
                    if s:IsA(StaticFindObject(SPAWNER_BP)) then
                        s:Save()
                    end
                    n = n + 1
                    found[name] = true
                end
            end)
        end
        local owed, changed = game.owed.load(), false
        for id in pairs(ids) do
            local want = not found[id] or nil
            if owed[id] ~= want then
                owed[id], changed = want, true
            end
        end
        if changed then
            pcall(game.owed.save)
        end
        return n > 0
    end

    -- Every few seconds while any are owed: those not in use by a session right now (keep: id -> true) are tried again.
    function game.owed.retry(keep)
        local try = {}
        for id in pairs(game.owed.load()) do
            if not (keep and keep[id]) then
                try[id] = true
            end
        end
        if next(try) then
            game.putBack(try)
        end
    end

    -- Cached for ENEMY_CACHE_S: the host and client halves (and aggro) all ask within the same tick.
    -- fresh = true skips the cache.
    local ENEMY_CACHE_S = 1.0
    local enemyCache, enemyAddrs, enemyCacheAt = nil, nil, nil

    -- The list as it stands, without searching for anything: for work that can wait for the next look.
    function game.enemiesSoFar()
        return enemyCache or {}, enemyAddrs or {}
    end

    -- The enemies, and their addresses in the same order.
    function game.listEnemies(fresh)
        local now = os.clock()
        if not fresh and enemyCache ~= nil and now - enemyCacheAt < ENEMY_CACHE_S then
            return enemyCache, enemyAddrs
        end
        searched()
        if os.clock() - factsAt >= ACTOR_FACTS_S then
            game.forgetActors()
        end
        local out, addrs = {}, {}
        for _, ch in ipairs(FindAllOf("PBZCharacter_NPC") or {}) do
            local addr = ch:GetAddress()
            local enemy = knownEnemy[addr]
            if enemy == nil then
                enemy = isEnemy(ch)
                knownEnemy[addr] = enemy
                if enemy and layout then
                    local cn = className(ch)
                    layoutChecked[cn] = layoutChecked[cn] or checkLayout(ch, addr)
                end
            end
            if enemy then
                out[#out + 1] = ch
                addrs[#addrs + 1] = addr
            end
        end
        enemyCache, enemyAddrs, enemyCacheAt = out, addrs, now
        return out, addrs
    end

    function game.getHealth(actor)
        if layout then
            local x, _, _, _, _, _, _, _, hp, maxhp = link.read(actor:GetAddress())
            if x then
                return hp, maxhp
            end
        end
        local ok, hp, maxhp = pcall(function()
            local set = actor.AttributeSetBase
            return set.Health.CurrentValue, set.Health_Max.CurrentValue
        end)
        -- A stale actor (e.g. one replaced by a respawn) can hand back an object instead of a number.
        if ok and type(hp) == "number" and type(maxhp) == "number" then
            return hp, maxhp
        end
        return nil, nil
    end

    -- The HUD's boss bars now, valid ones only (asked for each time: no widget kept across frames).
    local function bossBarList(hud)
        local out = {}
        pcall(function()
            local bars = hud:GetBossHPBarInstances()
            for i = 1, #bars do
                local bar = nil
                pcall(function() bar = bars[i]:get() end)
                if valid(bar) then
                    out[#out + 1] = bar
                end
            end
        end)
        return out
    end

    -- A value written here reaches no attribute listener, so the health bar on an enemy wouldn't move: it's told itself.
    -- The bar only exists once the game has shown it, and boss bars live on the HUD.
    local function refreshBar(actor, hp, maxhp)
        if not maxhp or maxhp <= 0 then
            return
        end
        pcall(function()
            local w = actor.hpbar:GetUserWidgetObject()
            if valid(w) then
                w:ForSeq_UpdateHealth(hp / maxhp)
            end
        end)
        if game.bossAt(actor:GetAddress(), actor) then
            pcall(function()
                local addr = actor:GetAddress()
                local hud = FindFirstOf("PBZHUDLayout")
                if not valid(hud) then
                    return          -- (no HUD, mid-load: a call on nothing is a crash in UE4SS, not an error)
                end
                local bars = hud:GetBossHPBarInstances()
                for i = 1, #bars do
                    local bar = bars[i]:get()
                    if valid(bar) and (not valid(bar.Character) or bar.Character:GetAddress() == addr) then
                        bar:ForSeq_UpdateHealth(hp / maxhp)
                    end
                end
            end)
        end
    end

    -- The bar we put up for the other PC's fight can go without a word (no UnRegisterBossHPBar: a mirrored boss has no
    -- fight of its own here). Asked about once a second while such a fight goes on.
    local BAR_TRIES = 3
    local barTries = {}
    function game.keepBossBar(boss)
        local addr = boss:GetAddress()
        local shown = false
        local hud = FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            return true             -- (no HUD, mid-load: asked again next time, not counted as a bar gone)
        end
        pcall(function()
            local bars = hud:GetBossHPBarInstances()
            for i = 1, #bars do
                local bar = bars[i]:get()
                -- (A bar has no Character until its Init has run.)
                if valid(bar) and (not valid(bar.Character) or bar.Character:GetAddress() == addr) then
                    shown = true
                end
            end
        end)
        if shown then
            barTries[addr] = nil
        else
            -- (Asked again and again it flickers, like a second bar: the game may simply not want one here.)
            barTries[addr] = (barTries[addr] or 0) + 1
            if barTries[addr] > BAR_TRIES then
                return false
            end
            bosses[addr] = nil
            game.showBossBar(boss)
            local hp, maxhp = game.getHealth(boss)
            game.after(0.3, function()
                if valid(boss) and hp then
                    refreshBar(boss, game.getHealth(boss), maxhp)
                end
            end)
        end
        return shown
    end

    -- The host's maximum on a copy, its share of health left as it is: game.setHealth follows on its own.
    function game.setMaxHealth(actor, maxhp)
        pcall(function()
            local mx = actor.AttributeSetBase.Health_Max
            mx.BaseValue = maxhp
            mx.CurrentValue = maxhp
        end)
    end

    function game.setHealth(actor, hp)
        local cur, maxhp = game.getHealth(actor)
        if cur == nil or math.abs(cur - hp) < 0.5 then
            return
        end
        syncing = true
        pcall(function()
            local h = actor.AttributeSetBase.Health
            h.BaseValue = hp
            h.CurrentValue = hp
        end)
        syncing = false
        refreshBar(actor, hp, maxhp)
    end

    -- IsDead() stayed false on a thug at 0 HP during its death animation, so health counts too.
    function game.isDead(actor)
        local hp = game.getHealth(actor)
        if hp ~= nil and hp <= 0 then
            return true
        end
        local ok, dead = pcall(function() return actor:IsDead() end)
        return ok and dead == true
    end

    -- A boss that died (or a bell respawn, see coop.lua) leaves the registry, so its next fight is announced again.
    local function forgetBoss(actor)
        pcall(function() bosses[actor:GetAddress()] = nil end)
    end

    -- A boss bar is up: a fight the game started, or the partner's (showBossBar). Live bosses only: a boss that went
    -- without a word left its entry behind, and this stayed true after the fight (it pauses the revive timer).
    function game.bossFightActive()
        return #game.bossActors() > 0
    end

    -- A boss fight's boss at this address, and still that actor (by its name): one unloaded mid-fight without a word left its
    -- address marked, and the enemy that got the address next was taken for the boss (its health on the bar, its items
    -- sent as a boss's). A stale mark is dropped.
    function game.bossAt(addr, actor)
        local mark = bosses[addr]
        if not mark then
            return false
        end
        if mark == true or actor == nil then
            return true
        end
        local ok, name = pcall(function() return actor:GetFName():ToString() end)
        if ok and name == mark then
            return true
        end
        bosses[addr], bossActors[addr] = nil, nil
        return false
    end

    -- The bosses of the fights going on: live actors only.
    function game.bossActors()
        local out = {}
        for addr, actor in pairs(bossActors) do
            if valid(actor) and game.bossAt(addr, actor) and not game.isDead(actor) then
                out[#out + 1] = actor
            else
                -- Gone without a word (the player's own death reloads the fight): the fight is over for us too.
                bossActors[addr] = nil
                bosses[addr] = nil
            end
        end
        return out
    end

    -- Everyone respawned: no fight goes on, and a bar we put up ourselves doesn't go by itself.
    function game.resetBosses()
        local hud = next(bossActors) and FindFirstOf("PBZHUDLayout")
        for _, actor in pairs(bossActors) do
            if valid(hud) and valid(actor) then
                pcall(function() hud:UnRegisterBossHPBar(actor) end)
            end
        end
        bosses, bossActors = {}, {}
    end

    -- Health_Min: the floor native damage can't push health below. The client holds its copies of the host's
    -- enemies at 1 so only the host decides when one dies (coop.lua); 0 is the game's normal.
    -- The floor native damage can't push its health below (0 if none, or unread).
    function game.healthFloor(actor)
        local ok, v = pcall(function() return actor.AttributeSetBase.Health_Min.CurrentValue end)
        return (ok and type(v) == "number") and v or 0
    end

    function game.setMinHealth(actor, value)
        pcall(function()
            local m = actor.AttributeSetBase.Health_Min
            m.BaseValue = value
            m.CurrentValue = value
        end)
    end

    -- A blow already swinging when the enemy dies must not land: its hit windows live in the montage, and a replayed
    -- attack doesn't end by itself on a copy nothing steers any more.
    local function stopSwing(actor)
        pcall(function()
            local mesh = actor.Mesh
            local ai = valid(mesh) and mesh:GetAnimInstance() or nil
            if not valid(ai) then
                return      -- (a body taken off the world has none: a call on nothing is a crash, pcall or not)
            end
            local m = ai:GetCurrentActiveMontage()
            if valid(m) then
                ai:Montage_Stop(0.1, m)
            end
        end)
    end

    -- Its health bar, off: a copy killed here went (or lay there) with its bar still floating over the spot.
    function game.hideHealthBar(actor)
        pcall(function()
            local bar = actor.hpbar
            if valid(bar) then
                bar:SetVisibility(false, true)
            end
        end)
    end

    function game.kill(actor)
        game.hideHealthBar(actor)
        local boss = game.isBoss and game.isBoss(actor)
        -- (A boss's ghost twin is no boss to the mod, but it's a boss to the game: it shrugs off the game-logic reason
        -- as the boss does, and stood on at 0 health, unseen once the dissolve hid it.)
        if not boss and twin.at(actor:GetAddress(), actor) then
            boss = game.isBossClass(className(actor))
        end
        forgetBoss(actor)
        game.setMinHealth(actor, 0)
        stopSwing(actor)
        if boss then
            -- Bosses shrug off the game-logic reason: the guest's lived on with the fog walls open.
            game.applyDamage(actor, math.huge, 0)
            return
        end
        syncing = true
        local ok, err = pcall(function() actor:Kill(DIE_GAME_LOGIC) end)
        syncing = false
        if not ok then
            log("Kill failed: " .. tostring(err))
        end
        -- This kill leaves the health as it was (30 on a thug), and some 10 s on, as the game clears the body away, it stops
        -- saying it's dead: read then, it was a live enemy again, sent to the partner, brought back there, handed over.
        game.setHealth(actor, 0)
    end

    -- An enemy copy dies here as the host's did. The quiet kill alone left it standing, frozen, until it went; the game's
    -- own death (its kill effect) pays this player its dust a moment later, whatever the enemy's level, and the host's
    -- kill already reaches them as shared dust. So: the quiet kill, then the game's death dissolve on each skeletal mesh
    -- of its body and what it holds (as the game puts it there), and the body hidden as the dissolve takes it.
    local DISSOLVE = { PATH = "/PBZVFXPack/VFX/BattleFX/Common/NS_DeathDissolve_001.NS_DeathDissolve_001", HIDE_S = 1.6 }

    function DISSOLVE.meshes(actor)
        local out = {}
        pcall(function()
            local skel = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
            if not actor:IsA(StaticFindObject("/Script/Engine.Character")) then
                return
            end
            local function add(c, depth)
                if c:IsA(skel) then
                    out[#out + 1] = c
                end
                if depth < 2 then
                    for i = 0, c:GetNumChildrenComponents() - 1 do
                        local child = c:GetChildComponent(i)
                        if valid(child) then
                            add(child, depth + 1)
                        end
                    end
                end
            end
            add(actor.Mesh, 0)
        end)
        return out
    end

    function game.dissolveKill(actor)
        game.kill(actor)
        pcall(function()
            local sys = StaticFindObject(DISSOLVE.PATH)
            if not valid(sys) and type(LoadAsset) == "function" then
                pcall(LoadAsset, DISSOLVE.PATH)
                sys = StaticFindObject(DISSOLVE.PATH)
            end
            local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
            for _, mesh in ipairs(valid(sys) and DISSOLVE.meshes(actor) or {}) do
                lib:SpawnSystemAttached(sys, mesh, FName("None"), { X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
                    0, true, true, 0, true)
            end
        end)
        local addr, name = actor:GetAddress(), actor:GetFName():ToString()
        game.after(DISSOLVE.HIDE_S, function()
            -- (And by name: one respawned at that address in the meantime was hidden for good. Found again in a fresh list,
            -- not the actor of 1.6 s ago: one the game had cleared away could read as valid.)
            for _, a in pairs(game.listEnemies() or {}) do
                if valid(a) and a:GetAddress() == addr and select(2, pcall(function() return a:GetFName():ToString() end)) == name then
                    for _, mesh in ipairs(DISSOLVE.meshes(a)) do
                        pcall(function() mesh:SetVisibility(false, true) end)
                    end
                end
            end
        end)
    end

    -- The player's own death, the game's normal flow (screen, respawn, refresh): the game's own kill effect. A player has
    -- no Kill, and health set to 0 by hand only leaves them lying there with no way back.
    local KILL_EFFECT = "/Game/PBZContent/Blueprint/Ability/GameplayEffects/GE_Kill"
    local function applyKillEffect(actor)
        return pcall(function()
            local effect = StaticFindObject(KILL_EFFECT .. ".GE_Kill_C")
            if not valid(effect) then
                LoadAsset(KILL_EFFECT)
                effect = StaticFindObject(KILL_EFFECT .. ".GE_Kill_C")
            end
            -- (Asked of each, never called on nothing: in UE4SS that's a crash, not an error.)
            local asc = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
                :GetAbilitySystemComponent(actor)
            if not (valid(effect) and valid(asc)) then
                error("no kill effect or ability system")
            end
            asc:BP_ApplyGameplayEffectToSelf(effect, 1.0, {})
        end)
    end

    -- A loot card the game put up and never finished: no button to focus, so no key confirms it, and the player is stuck
    -- behind it. Seen when a boss of the partner's world was ended here the moment its fight began: its reward's card came up
    -- in the middle of that. The backpack holds no card by then and the item is in it already; the card's own confirm closes
    -- it. A card the backpack still holds, or one with its button, is left alone. Returns how many were closed.
    function game.closeStuckCards(pawn)
        local bp = valid(pawn) and game.backpackOf(pawn)
        local showing = true
        pcall(function() showing = bp.bShowPickItemWidget == true end)
        if not bp or showing then
            return 0
        end
        local n = 0
        for _, w in ipairs(FindAllOf("W_pickupgear_C") or {}) do
            pcall(function()
                if valid(w) and w:IsVisible() and not valid(w.CurrentFocusButton) then
                    w:ClickBackKey()
                    n = n + 1
                end
            end)
        end
        if n > 0 then
            log(n .. " item card(s) the game left without buttons, closed: the item is in the backpack.")
        end
        return n
    end

    function game.killPlayer(pawn)
        game.setMinHealth(pawn, 0)
        local ok, err = applyKillEffect(pawn)
        if not ok then
            log("Kill failed: " .. tostring(err))
        end
    end

    -- A copy of the partner's boss, dead the game's whole way: this world's story goes on as the partner's does, the scene
    -- after the fight first. Its loot is rolled at level 0, which pays nothing: the partner's death paid already, and that
    -- dust reaches this player from there. Falls back to the quiet kill if the effect doesn't take.
    function game.killForReal(actor)
        local boss = game.isBoss and game.isBoss(actor)
        -- (A boss's level, floor and bar as they were: put back if the game won't let it die now. Left at level 0, with no
        -- floor, bar or boss record, it fought on unknown as a boss, and its real death later paid nothing.)
        local level0, floor0 = nil, game.healthFloor(actor)
        pcall(function() level0 = actor.AttributeSetBase.Level.CurrentValue end)
        game.hideHealthBar(actor)
        pcall(function()
            local level = actor.AttributeSetBase.Level
            level.BaseValue = 0
            level.CurrentValue = 0
        end)
        stopSwing(actor)
        game.setMinHealth(actor, 0)
        syncing = true
        local ok = applyKillEffect(actor)
        syncing = false
        local hp = game.getHealth(actor)
        if ok and hp ~= nil and hp <= 0 then
            forgetBoss(actor)
            return true
        end
        if boss then
            -- A boss the game won't let die now isn't forced (see applyDamage): as it was.
            pcall(function()
                if type(level0) == "number" then
                    local level = actor.AttributeSetBase.Level
                    level.BaseValue = level0
                    level.CurrentValue = level0
                end
            end)
            game.setMinHealth(actor, floor0)
            pcall(game.showBossBar, actor)
            return false
        end
        forgetBoss(actor)
        -- (Refused: tried once more a moment on, the copy found again by address and name, then the quiet kill with the
        -- death's dissolve, the body out of reach. The quiet kill alone stood frozen and still took blows till the game
        -- cleared it some 10 s on: "after P2 empties a mob's bar it can still be hit, and the model vanishes seconds
        -- later" (1.6.3's report 1). Said once a kind of enemy, with what might have stopped it.)
        local addr = actor:GetAddress()
        local fname = select(2, pcall(function() return actor:GetFName():ToString() end))
        DISSOLVE.refused = DISSOLVE.refused or {}
        local kind = tostring(className(actor))
        if not DISSOLVE.refused[kind] then
            DISSOLVE.refused[kind] = true
            log(string.format("The game refused a %s's death here (health %s, hit state %s): tried again, then dissolved.",
                kind, tostring(hp), tostring(game.hitStateOf and select(1, game.hitStateOf(actor)))))
        end
        if game.stopAI then
            game.stopAI(actor)
        end
        game.after(0.35, function()
            local again = nil
            for _, a in pairs(game.listEnemies() or {}) do
                if valid(a) and a:GetAddress() == addr
                    and select(2, pcall(function() return a:GetFName():ToString() end)) == fname then
                    again = a
                end
            end
            if not again or game.isDead(again) then
                return              -- (gone, or dead by now: a blow of this player's own, say)
            end
            game.setMinHealth(again, 0)
            syncing = true
            local ok2 = applyKillEffect(again)
            syncing = false
            local hp2 = game.getHealth(again)
            if not (ok2 and hp2 ~= nil and hp2 <= 0) then
                game.dissolveKill(again)
                pcall(function() again:SetActorEnableCollision(false) end)
            end
        end)
        return false
    end

    -- Posture ("Shachi"): breaking it opens an execution.
    function game.getPosture(actor)
        if layout then
            local x, _, _, _, _, _, _, _, _, _, posture = link.read(actor:GetAddress())
            if x then
                return posture
            end
        end
        local ok, v = pcall(function() return actor.AttributeSetBase.Shachi.CurrentValue end)
        return (ok and type(v) == "number") and v or nil
    end

    -- A boss's posture written here reaches no listener either: the gold strip under its health (BreakmeterBar) stood
    -- still at a partner's blows while the health beside it moved (issue #16; the bench, 11-11). Its bar is told with its
    -- own ForSeq_UpdateShachi, as a PvP foe's strip is (setFoeShachi): the bar started with this boss (its Character, see
    -- showBossBar), or else one nobody started, as its health is told (refreshBar). Not that in a match: a foe's has none.
    local function refreshShachi(actor, value)
        local addr = actor:GetAddress()
        if not game.bossAt(addr, actor) then
            return
        end
        local ok, max = pcall(function() return actor.AttributeSetBase.Shachi_Max.CurrentValue end)
        if not (ok and type(max) == "number" and max > 0) then
            return
        end
        local hud = FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            return          -- (no HUD, mid-load: a call on nothing is a crash in UE4SS, not an error)
        end
        local own, unstarted = nil, {}
        for _, bar in ipairs(bossBarList(hud)) do
            local who = nil
            pcall(function() who = bar.Character end)
            if valid(who) then
                if who:GetAddress() == addr then
                    own = bar
                end
            else
                unstarted[#unstarted + 1] = bar
            end
        end
        local inMatch = api.coop and api.coop.net and api.coop.net.arena
        for _, bar in ipairs(own and { own } or (inMatch and {} or unstarted)) do
            pcall(function() bar:ForSeq_UpdateShachi(math.max(0, math.min(1, value / max))) end)
        end
    end

    function game.setPosture(actor, value)
        syncing = true
        pcall(function()
            local s = actor.AttributeSetBase.Shachi
            s.BaseValue = value
            s.CurrentValue = value
        end)
        syncing = false
        refreshShachi(actor, value)
    end

    -- A bar a partner's hit emptied (player report 11-07): written to 0 here, the game's own break never ran, so nothing
    -- ever filled it again. The boss stood at 0 for good, the guest's copy followed it there, and every guest hit
    -- staggered it. So a bar a partner emptied that is still empty POSTURE_BREAK_S on (no break of the game's own
    -- filled it) is filled to its max here, as the game's break does. Keyed by address, no actor kept.
    game.POSTURE_EMPTY, game.POSTURE_BREAK_S, game.postureEmptied = 1.5, 6, {}   -- (empty: the game holds an emptied bar at 1)
    -- The bar as broken: a two-hundredth of it, at least POSTURE_EMPTY. The game holds a broken bar a little above 0, the
    -- Gold-Masked One's at 1.64 of 1055 and the elite swordsman's at 4 of 2558 (bench, 11-10; about 0.16% of each).
    -- Above 1.5, the bar a partner broke was taken for one the game had filled again: it never filled, and it stood
    -- broken for good. (Not much more: a bar a little higher is a bar one blow short of a break, still standing.)
    function game.emptyBar(actor)
        local ok, max = pcall(function() return actor.AttributeSetBase.Shachi_Max.CurrentValue end)
        return math.max(game.POSTURE_EMPTY, (ok and type(max) == "number") and max * 0.005 or 0)
    end
    function game.refillEmptied(actor, addr, posture)
        local at = game.postureEmptied[addr]
        if not at or posture == nil then
            return posture
        end
        -- (The share of the bar only once it's over 1.5: read every turn of every enemy with a pending refill, it cost.)
        if posture > game.POSTURE_EMPTY and posture > game.emptyBar(actor) then
            game.postureEmptied[addr] = nil       -- (filled already: the game's own break ran)
            return posture
        end
        if os.clock() - at < game.POSTURE_BREAK_S then
            return posture
        end
        game.postureEmptied[addr] = nil
        local ok, max = pcall(function() return actor.AttributeSetBase.Shachi_Max.CurrentValue end)
        if not (ok and type(max) == "number" and max > game.POSTURE_EMPTY) then
            return posture
        end
        game.setPosture(actor, max)
        log(string.format("Posture bar a partner emptied was still empty after %d s: filled to %.0f.", game.POSTURE_BREAK_S, max))
        return max
    end

    -- A boss's posture and a partner's blows (player reports on 1.6.9: "after the boss's guard is broken, it keeps getting
    -- hitstunned ... it can't fight back until we kill it"). The game can't weigh a blow that only comes reported, so its
    -- rules for one are kept here, on both PCs. Bench, 11-10, the Gold-Masked One, both players swinging every 0.5 s for
    -- 30 s: every guest blow took posture (the host's were mostly deflected or dodged, one in four landed), so it broke
    -- again 4 to 5 s after each fill, 5 breaks in all, 21 s of the 30 reacting and 9 moves of its own; the host alone
    -- broke it once and it fought back, 23 moves. A partner's blow takes no posture from a boss:
    -- - in a break of its own and the fill after it: the game's own blows take none then either, and written into the fill
    --   they held it down;
    -- - for BOSS_RECOVER_S after its bar is back: it gets its fight back, as after a break alone (alone, the host's blows
    --   met its counters and deflects then). The same on both PCs, whatever each one's ini says;
    -- - while it turns blows aside, a deflect, parry or dodge: this world's blows don't land then either. (Not a guard or
    --   a block: those may cost it posture.)
    -- Its health takes every blow. Each turn feeds watchBossBar the bar this world's boss has (the host's own, a guest's
    -- copy the host's line), keyed by address, no actor kept.
    game.bossBars = {}
    game.BOSS_FILL_MAX_S, game.BOSS_RECOVER_S, game.BOSS_SETTLE_S = 12, 6, 0.5
    function game.watchBossBar(actor, addr, posture)
        if posture == nil then
            return
        end
        local b = game.bossBars[addr]
        local now = os.clock()
        if b == nil or now - b.seenAt > 30 then
            b = {}
            game.bossBars[addr] = b
        end
        if not b.empty or now - b.emptyAt > 1 then
            b.empty, b.emptyAt = game.emptyBar(actor), now
        end
        if posture <= b.empty then
            b.brokeAt = now
        elseif b.last and posture > b.last + 0.5 then
            b.risingAt = now
        end
        b.last, b.seenAt = posture, now
        -- (Back once it has risen since its break and has held still a moment: the fill's end, or the jump of
        -- refillEmptied.)
        if b.brokeAt and (b.upAt or -1) < b.brokeAt and (b.risingAt or -1) > b.brokeAt
            and now - b.risingAt >= game.BOSS_SETTLE_S then
            b.upAt = now
        end
    end

    -- A deflect, parry or dodge, by the move's name or its folder (the game files them under /Dodge/ and /Deflect/): none
    -- of the game's own tags says so (bench, 11-10). Not an attack that comes out of one (the Gold-Masked One's
    -- DoggeAttack, Deflect_Atk2), a reaction (Deflect_Break), nor a boss's opening after the player's perfect dodge
    -- (Dodged_By_Hun).
    game.ASIDE_WORDS = { "deflect", "parry", "dodge", "dogge", "evade", "_roll", "backstep" }
    game.ASIDE_NOT = { "attack", "atk", "break", "dodged", "_by_hun", "_hit" }
    function game.turnsAside(actor)
        local name, path = nil, nil
        pcall(function()
            local m = actor.Mesh:GetAnimInstance():GetCurrentActiveMontage()
            if valid(m) then
                name = m:GetFName():ToString():lower()
                path = m:GetFullName():lower()
            end
        end)
        if not name then
            return false
        end
        for _, w in ipairs(game.ASIDE_NOT) do
            if name:find(w, 1, true) then
                return false
            end
        end
        if path and (path:find("/dodge/", 1, true) or path:find("/deflect/", 1, true)) then
            return true
        end
        for _, w in ipairs(game.ASIDE_WORDS) do
            if name:find(w, 1, true) then
                return true
            end
        end
        return false
    end

    -- Why this boss takes no posture from a partner's blow now ("break", "recover", "aside"), or nil. line: a guest's copy,
    -- its bar the host's line: its own hit state is left out (a break of the copy's that this very blow made isn't the
    -- host's boss's, and the copy's own game takes no posture in one of its own).
    function game.partnerRefuses(actor, addr, line)
        local now = os.clock()
        local b = game.bossBars[addr]
        local state = not line and game.hitStateOf and game.hitStateOf(actor)
        if state and state:find("State.Break", 1, true) then
            return "break"
        end
        -- (Filling: risen since its break and not back yet. A bar a partner's write left empty, no break of the game's
        -- and no fill, isn't one: the copy's break that follows must still play here.)
        if b and b.brokeAt and (b.upAt or -1) < b.brokeAt and (b.risingAt or -1) > b.brokeAt
            and now - b.brokeAt < game.BOSS_FILL_MAX_S then
            return "break"
        end
        if b and b.upAt and now - b.upAt < game.BOSS_RECOVER_S then
            return "recover"
        end
        if game.turnsAside(actor) then
            return "aside"
        end
        return nil
    end

    -- Host: the client's player hit this enemy. Lower its health and posture; at zero health, let the game run
    -- its death. real: through the game's own kill effect, the whole death as from this player's own blow, so this world
    -- pays its player and a boss's story goes on (its scene after the fight, its reward). Kill() skips all that: a boss
    -- the guest finished gave the host nothing and came back. Returns true when that real death ran.
    function game.applyDamage(actor, amount, postureDamage, real)
        local hp = game.getHealth(actor)
        if hp == nil or hp <= 0 then
            return false
        end
        local posture = game.getPosture(actor)
        if posture and postureDamage and postureDamage > 0 then
            game.setPosture(actor, math.max(0, posture - postureDamage))
            -- (A blow that empties it, to fill again 6 s on (refillEmptied). Not one that leaves it a little up, one short of
            -- a break: filled, its whole bar of work was thrown away. And not stamped again while one waits: put off, a
            -- bar held at 0 by blows went unfilled.)
            local addr = actor:GetAddress()
            if posture > game.POSTURE_EMPTY and posture - postureDamage <= game.POSTURE_EMPTY
                and not game.postureEmptied[addr] then
                game.postureEmptied[addr] = os.clock()
            end
        end
        local left = math.max(0, hp - amount)
        -- A floor the game set on its own (a boss whose phase ends in a scene: the forest's last boss, YuCong): not crossed by
        -- a partner's blow. Zeroed and killed, the boss died outside its script: no scene after it, the body stayed, and the
        -- trip on to Lu Family Village never opened, in the host's save for good. Left just above it, the next blow here
        -- (this player's own, through the game) crosses it, and the game does the rest.
        local floor = game.healthFloor(actor)
        -- (A boss's only: an enemy held at a floor of the mod's own (a host's copy of one the guest's game ran) stood at 2 for
        -- good, the guest's copy at 1.)
        if floor >= 1 and left <= floor and game.isBoss and game.isBoss(actor) then
            game.setHealth(actor, math.min(hp, floor + 1))
            return false
        end
        if left <= 0 and real then
            forgetBoss(actor)
            stopSwing(actor)
            game.setMinHealth(actor, 0)
            syncing = true
            local ok = applyKillEffect(actor)
            syncing = false
            local after = game.getHealth(actor)
            if ok and after ~= nil and after <= 0 then
                return true
            end
            if game.isBoss and game.isBoss(actor) then
                -- The game wouldn't let its boss die now (between phases, its health locked for a scene to come): not forced
                -- through with the quiet kill below. Forced, the forest's last boss died outside its script, its body stayed,
                -- no scene came, and the trip on to Lu Family Village never opened in the host's save. Left at 1, for the game.
                game.setHealth(actor, math.max(1, math.min(hp, after or 1)))
                return false
            end
        end
        game.setHealth(actor, left)
        if left <= 0 then
            forgetBoss(actor)
            stopSwing(actor)
            syncing = true
            pcall(function() actor:Kill(DIE_DAMAGED) end)
            syncing = false
        end
        return false
    end

    -- A native kill (death by damage) rolls the enemy's loot table (GetCombatLootDataForOwner, owner = the enemy,
    -- at its "Level" attribute). Kill(), which the host uses for the client's killing blow, skips it, so that kill
    -- would pay nothing: the host rolls the same table here. Returns dust and a list of { id, count, kind }, where kind
    -- is nil for props or "weapon", "weapon2" (not a normal weapon), "medicine", "accessory".
    -- (Prologue enemies are level 0, which pays nothing; "lootlevel <n>" overrides the level for testing.)
    game.lootLevelOverride = nil
    function game.rollLoot(actor)
        local level = game.lootLevelOverride
        if level == nil then
            local ok, v = pcall(function() return actor.AttributeSetBase.Level.CurrentValue end)
            level = (ok and type(v) == "number") and math.floor(v + 0.5) or 0
        end
        local data = {}
        if not pcall(function() actor:GetCombatLootDataBySelf(level, data) end) then
            return 0, {}, level
        end
        local dust = tonumber(data.LootDust) or 0
        local items = {}
        local function add(id, count, kind)
            items[#items + 1] = { id = id, count = math.max(1, math.floor(tonumber(count) or 1)), kind = kind }
        end
        -- Out parameters come back as plain Lua tables, not the game's containers: the ForEach this used to call isn't
        -- there, so no item was ever read. Keys and entries are names, as strings or objects.
        local function text(v)
            if type(v) == "string" then
                return v
            end
            local ok, s = pcall(function() return v:ToString() end)
            return ok and s or nil
        end
        for k, v in pairs(type(data.LootItems) == "table" and data.LootItems or {}) do
            if text(k) then
                add(text(k), v)
            end
        end
        for k, v in pairs(type(data.LootWeapons) == "table" and data.LootWeapons or {}) do
            if text(k) then
                add(text(k), 1, v == false and "weapon2" or "weapon")
            end
        end
        for field, kind in pairs({ Medicines = "medicine", Accessories = "accessory" }) do
            for _, v in pairs(type(data[field]) == "table" and data[field] or {}) do
                if text(v) then
                    add(text(v), 1, kind)
                end
            end
        end
        return dust, items, level
    end

    -- One item of a loot roll, into this player's backpack. Weapons, medicines and accessories each have their own way in.
    -- (GiveItem answers without complaint and adds neither of the last two.) quiet: no pickup card at all, for the catch-up
    -- on joining (game.mergeBag), which gave a new player a card to close with Escape for each thing the host had (the
    -- user: "we only should display items collected after joining not when first joining").
    function game.grantLoot(pawn, itemId, kind, count, quiet)
        count = count or 1
        local bp = valid(pawn) and worldSubsystem(pawn, "/Script/ProjectPBZ.PBZBackPackSubsystem")
        if not bp then
            return
        end
        game.granting = true        -- (what the mod adds isn't sent back: see "what the game gives")
        if kind == "weapon" or kind == "weapon2" then
            -- (No "equip it now?": that's a full screen, and with a partner linked the game doesn't pause for it.)
            pcall(function() bp:AddWeaponItem(FName(itemId), kind == "weapon", false, false, false) end)
            log("Shared loot: weapon " .. itemId)
        elseif kind == "medicine" and itemId == "Hulu" then
            -- (Never the starting healing gourd: the game hands it out itself as the prologue ends, equipped. Pushed in from
            -- the partner beforehand, unequipped, a new game's player had it in the bag and none to drink from.) (The flag down
            -- first: left up, every later find of this player's went unshared.)
            game.granting = false
            return
        elseif kind == "medicine" then
            -- (MedicineID, bAutoEquip, bShowPickupUI.)
            pcall(function() bp:PushMedicineToInventory(FName(itemId), false, not quiet) end)
            log("Shared loot: medicine " .. itemId)
        elseif kind == "accessory" then
            pcall(function() bp:PushAccessoryToInventory(FName(itemId), false) end)
            log("Shared loot: accessory " .. itemId)
        else
            -- AddPropsToBackPack is the backpack's own entry point; if the item count didn't move (seen in the
            -- prologue map, which keeps its own restricted backpack), fall back to the player's GiveItem.
            -- (Notes and keys, R_ and I_, aren't counted in the backpack: no second try for those.)
            local before = game.itemCount(bp, itemId)
            local counted = not itemId:find("^[RI]_%d")
            -- What a partner found shows on the right, as the game shows a find of this player's (the user, 11-09: "people
            -- want to be notified what their friends picked up on the right same as when you pick items the small
            -- notification that appears"): the backpack's notice flag on, then shown at once (game.showPickupTips). Not for a
            -- catch-up (quiet). A quest item, a note or a key keeps the game's full-screen card, at the game's own moment (a
            -- player report, 11-06: the other player saw nothing of what their partner found). game.granting keeps the
            -- notice's own report from going back.
            local line = not quiet and counted and not game.isNarrative(itemId)
            local card = not quiet and not line and (before == 0 or game.isNarrative(itemId))
            local held = 0
            if line and before == 0 then
                -- (A thing new to this player gets the card, not the line, and the card takes the screen in a game that isn't
                -- paused for it. Held a moment first, quietly, the game counts it seen and shows the line: the bench, 11-09.)
                pcall(function() bp:AddPropsToBackPack(1, FName(itemId), false) end)
                if game.itemCount(bp, itemId) == 1 then
                    pcall(function() bp:RemovePropsFromBackPack(1, FName(itemId), false) end)
                end
                held = game.itemCount(bp, itemId)      -- (0: taken back; 1: it came in some other way, and stays given)
            end
            if count > held then
                pcall(function() bp:AddPropsToBackPack(count - held, FName(itemId), line or card) end)
            end
            if line then
                game.tipsWanted = true
            elseif card then
                game.cardIds[itemId] = true
            end
            local after = game.itemCount(bp, itemId)
            -- (Not when quiet: GiveItem is the player blueprint's own helper, with no way to keep its card down. Only when the
            -- count didn't move at all: one that fell, a fourth amber shard made into an amber as it came, got a second.)
            if after == before and counted and not quiet then
                pcall(function() pawn:GiveItem(FName(itemId), count) end)
                after = game.itemCount(bp, itemId)
            end
            log(string.format("Shared loot: %s x%d (%d -> %d)%s", itemId, count, before, after, line and ", on the right" or ""))
            -- Its own flag while it's held ("ljc.小雪.收集物1", one of the relics for the Bagua boy): the game raises it as
            -- its pickup card closes. A quiet add has no card (the bag on joining) and a shared one waits for the game's own
            -- moment, often long after (the bench, 11-11): a quest counting the flag stayed short. It goes with the thing.
            game.isNarrative(itemId)
            local flag = game.heldFlags and game.heldFlags[itemId]
            if flag and after > 0 and api.flowsync and api.flowsync.raise then
                api.flowsync.raise({ flag }, itemId)
            end
        end
        game.granting = false
    end

    -- The game's own notice on the right (WB_ItemTips: "Forged Metal + 1") for what grantLoot gave with its flag. That only
    -- waits in the backpack's queue (PushGetPropInfos) till the game's own pickup flow shows it: the next chest this player
    -- opened (a report on 1.6.9: "all items will only show as picked up after opening the chest"). TryToPushPickupUI shows it
    -- now (the bench, 11-09), when the game can (CanPushPickupUI, no card up): else at the next look. A card in the queue (a
    -- note, a quest item) waits for the game's own moment with the rest, as it did: shown now it would take the screen
    -- mid-fight, in a game that isn't paused for it. (Fields, not locals: this file is at its 200.)
    game.tipsWanted, game.cardIds = false, {}
    function game.showPickupTips(pawn)
        local bp = valid(pawn) and worldSubsystem(pawn, "/Script/ProjectPBZ.PBZBackPackSubsystem")
        if not bp then
            return
        end
        local card = false
        pcall(function()
            bp.PushGetPropInfos:ForEach(function(_, e)
                card = card or game.cardIds[e:get().ItemName:ToString()] == true
            end)
        end)
        local ok, can = pcall(function() return bp:CanPushPickupUI() and not bp:IsDisplayPickupUI() end)
        if card or not ok then
            game.tipsWanted = false         -- (the game's own pickup flow shows them all: as before)
        elseif can and pcall(function() bp:TryToPushPickupUI() end) then
            game.tipsWanted = false
        end
    end

    game.commands.lootlevel = function(arg)
        game.lootLevelOverride = tonumber(arg)
        log("Loot level override: " .. tostring(game.lootLevelOverride) .. " (empty = the enemy's own level)")
    end

    function game.isBoss(actor, addr)
        addr = addr or actor:GetAddress()
        if twin.at(addr, actor) then
            return false
        end
        if game.bossAt(addr, actor) then
            return true
        end
        local known = knownBoss[addr]
        if known == nil then
            local cn = className(actor):gsub("_C$", "")
            if codexBoss[cn] == nil then
                local row = codexRow(cn)
                codexBoss[cn] = row ~= nil and row.bIsBoss == true
            end
            known = codexBoss[cn]
            knownBoss[addr] = known
        end
        return known
    end

    -- Whether a class (its name, "_C" or not) is a boss in the codex: for what a spawner will make, with nothing spawned.
    function game.isBossClass(cn)
        cn = tostring(cn):gsub("_C$", "")
        if codexBoss[cn] == nil then
            local row = codexRow(cn)
            codexBoss[cn] = row ~= nil and row.bIsBoss == true
        end
        return codexBoss[cn]
    end

    -- A boss's ghost twin (twins.lua): never the boss of a fight to the mod, but a boss to fight, by its class as the
    -- codex has it. It takes a partner's blows by a boss's rules (handlers.D): every flinch of theirs played on it, it never
    -- fought back either.
    function game.bossTwin(actor, addr)
        addr = addr or actor:GetAddress()
        if not twin.at(addr, actor) then
            return false
        end
        return game.isBossClass(className(actor)) == true
    end

    -- The HUD registers a boss health bar when a boss fight starts: the surest way to know who the boss is.
    local showingRemoteBoss = false
    local mirroredAt = {}       -- address -> true: a bar shown here for another player's fight (showBossBar)
    local foeBars = {}          -- address -> true: a PvP foe on the game's boss bar (game.showFoeBar), no boss to the mod
    pcall(function()
        RegisterHook("/Script/ProjectPBZ.PBZHUDLayout:RegisterBossHPBar", function(_, bossParam)
            local boss = bossParam:get()
            if valid(boss) and foeBars[boss:GetAddress()] then
                return
            end
            if valid(boss) and not showingRemoteBoss and mirroredAt[boss:GetAddress()] and game.bossAt(boss:GetAddress(), boss) then
                -- This game's own fight with a boss it showed for another player's: its own from now on. (A guest who
                -- started first had the host's own fight taken for a mirror, ended with the guest's: walls open, bar gone,
                -- the boss alive, its kill the host's alone.)
                mirroredAt[boss:GetAddress()] = nil
                if api.coop and api.coop.ownFightOn then
                    api.coop.ownFightOn(boss)
                end
            elseif valid(boss) and not game.bossAt(boss:GetAddress(), boss) and not twin.at(boss:GetAddress(), boss) then
                bosses[boss:GetAddress()] = boss:GetFName():ToString()
                bossActors[boss:GetAddress()] = boss
                log("Boss fight: " .. boss:GetFName():ToString())
                if api.coop and not showingRemoteBoss then
                    -- The same cross-PC id the snapshots use (sp:<SpawnerID> for spawner bosses).
                    game.refreshEnemyIds(true)
                    api.coop.announceBoss(boss)
                end
            end
        end)
    end)
    -- The bar goes away when the fight is over, or when the player's death reloads it with the boss still standing:
    -- either way there is no boss fight any more.
    pcall(function()
        RegisterHook("/Script/ProjectPBZ.PBZHUDLayout:UnRegisterBossHPBar", function(_, bossParam)
            local boss = bossParam:get()
            if valid(boss) then
                local addr = boss:GetAddress()
                if bosses[addr] then
                    log("Boss fight over: " .. boss:GetFName():ToString())
                end
                mirroredAt[addr] = nil
                bosses[addr] = nil
                bossActors[addr] = nil
            end
        end)
    end)

    -- A boss of this game's own fight, up again after a fall with no new bar from the game: known as in a fight again.
    -- False if it already is.
    function game.trackBoss(boss)
        if not valid(boss) or game.bossAt(boss:GetAddress(), boss) then
            return false
        end
        bosses[boss:GetAddress()] = boss:GetFName():ToString()
        bossActors[boss:GetAddress()] = boss
        log("Boss fight again: " .. boss:GetFName():ToString())
        return true
    end

    -- A boss bar's name after Init: a boss the codex has no row for it names by the boss's internal name
    -- (BP_Monster_GoldMaskMan_C_...), no name to show anyone. Left with none, as a bar put up unstarted has. (Here and for
    -- local co-op's player 2, localcoop.lua.)
    function game.noInternalName(bar, boss)
        pcall(function()
            if bar.BossName:GetText():ToString() == boss:GetFName():ToString() then
                bar.BossName:SetText(FText(""))
            end
        end)
    end

    -- The other player's game started a fight with this boss: show its health bar here too (our copy of the
    -- boss mirrors the host's health, so the bar follows the real fight).
    function game.showBossBar(boss)
        if not valid(boss) or game.bossAt(boss:GetAddress(), boss) then
            return
        end
        local hud = FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            log("No HUD layout to show the boss bar on.")
            return
        end
        local before = {}
        for _, bar in ipairs(bossBarList(hud)) do
            before[bar:GetAddress()] = true
        end
        showingRemoteBoss = true
        local ok, err = pcall(function() hud:RegisterBossHPBar(boss) end)
        showingRemoteBoss = false
        -- The new bar started with the boss (Init), as the game starts the bar of a fight of its own and local co-op starts
        -- player 2's: unstarted, its gold posture strip never moved, not even at this player's own blows (its health the
        -- HUD follows by itself). The bench, 11-11, issue #16. Any bar that isn't this boss's already: the HUD hands back a
        -- bar it took down, its Character and name as they were (a pool), and one still on the boss before (his body in the
        -- world, or the copy a pairing swapped out) was left on him, his name over this boss and its health and strip still.
        -- Init names it too, as the codex does: the elite swordsman "Jagged Steel, the Frenzied Brute". A boss the codex has
        -- no row for it names by its internal name (the Gold-Masked One's BP_Monster_GoldMaskMan_C_...): that one has none.
        if ok then
            for _, bar in ipairs(bossBarList(hud)) do
                if not before[bar:GetAddress()] then
                    pcall(function()
                        local who = bar.Character
                        if not (valid(who) and who:GetAddress() == boss:GetAddress()) then
                            bar:Init(boss)
                            game.noInternalName(bar, boss)
                        end
                    end)
                end
            end
        end
        mirroredAt[boss:GetAddress()] = true
        bosses[boss:GetAddress()] = boss:GetFName():ToString()
        bossActors[boss:GetAddress()] = boss
        log(ok and ("Showing boss bar for " .. boss:GetFName():ToString()) or ("Boss bar failed: " .. tostring(err)))
    end

    -- Whether this boss's bar is only the one shown here for another player's fight: the game's own bar on it (the hook
    -- above) makes it this game's fight too.
    function game.isMirrorBar(boss)
        return valid(boss) and mirroredAt[boss:GetAddress()] == true
    end

    -- A PvP foe's health on the game's own boss bar (arena.lua: the bars are the game's, not ours). Never a boss to the
    -- mod: kept out of bosses and bossActors, so nothing that walks the bosses (the host telling its fights, fog walls,
    -- scaling, the arena putting the real boss's bar away) sees it. name: what the bar says over it, or nil for the game's.
    -- A player's figure on a boss bar gets no Character (the bench: the bar showed, but pointed at nothing), so its bar is
    -- known by the widget the HUD made for it: the one that wasn't there before.
    -- (hud, here and below: the HUD this frame's caller found already, or nil to find it. Each FindFirstOf is a search of
    -- every object, and the match's bars asked for it several times a tick for each foe.)
    function game.showFoeBar(actor, name, hud)
        hud = valid(hud) and hud or FindFirstOf("PBZHUDLayout")
        if not (valid(actor) and valid(hud)) then
            return false
        end
        local addr = actor:GetAddress()
        local before = {}
        for _, bar in ipairs(bossBarList(hud)) do
            before[bar:GetAddress()] = true
        end
        foeBars[addr] = true
        if not pcall(function() hud:RegisterBossHPBar(actor) end) then
            return false
        end
        for _, bar in ipairs(bossBarList(hud)) do
            if not before[bar:GetAddress()] then
                foeBars[addr] = bar:GetAddress()
                if name then
                    pcall(function()
                        if api.lang and api.lang.arabic() then
                            game.arabicText(bar.BossName)       -- (the one font with Arabic: game.arabicFont)
                        else
                            game.ownText(bar.BossName)          -- (its own font back after a switch from Arabic)
                        end
                        bar.BossName:SetText(FText(name))
                    end)
                end
            end
        end
        return foeBars[addr] ~= true
    end

    -- Its bar, or nil. addr: the actor's address. (Registered but its bar not seen yet, if the HUD makes it a moment later:
    -- the first one nobody has claimed and with no Character is it. A real boss's bar has one.)
    function game.foeBar(addr, hud)
        local want = foeBars[addr]
        if not want then
            return nil
        end
        hud = valid(hud) and hud or FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            return nil
        end
        local bars = bossBarList(hud)
        if type(want) == "number" then
            for _, bar in ipairs(bars) do
                if bar:GetAddress() == want then
                    return bar
                end
            end
            return nil
        end
        local claimed = {}
        for _, a in pairs(foeBars) do
            if type(a) == "number" then
                claimed[a] = true
            end
        end
        for _, bar in ipairs(bars) do
            local ch = nil
            pcall(function() ch = bar.Character end)
            if not claimed[bar:GetAddress()] and not valid(ch) then
                foeBars[addr] = bar:GetAddress()
                return bar
            end
        end
        return nil
    end

    function game.setFoeBar(addr, fraction, hud)
        local bar = game.foeBar(addr, hud)
        if bar then
            pcall(function() bar:ForSeq_UpdateHealth(math.max(0, math.min(1, fraction))) end)
        end
        return bar ~= nil
    end

    -- The words over it (the game's own text, in its own font): the name, the score, the clock.
    function game.setFoeName(addr, name, hud)
        local bar = game.foeBar(addr, hud)
        if bar then
            pcall(function()
                if api.lang and api.lang.arabic() then
                    game.arabicText(bar.BossName)       -- (the one font with Arabic: game.arabicFont)
                else
                    game.ownText(bar.BossName)          -- (its own font back after a switch from Arabic)
                end
                bar.BossName:SetText(FText(name))
            end)
        end
        return bar ~= nil
    end

    function game.hideFoeBar(actor)
        local hud = FindFirstOf("PBZHUDLayout")
        if valid(actor) and valid(hud) then
            pcall(function() hud:UnRegisterBossHPBar(actor) end)
        end
        if valid(actor) then
            foeBars[actor:GetAddress()] = nil
        end
    end

    -- A foe's bar taken down by the figure it was put up for, when that isn't the slot's body any more (arenaui.lua): a
    -- figure made again had the new body's bar taken down, which wasn't up, and the old one stayed, frozen, its address
    -- still marked here (a boss given that address later was no boss to the mod: the hook above passes over it). A clone
    -- put away (coop.lua's destroyGhost) is never destroyed, so the HUD's own OnBossActorDestroyed never takes its bar: it's
    -- found again by address and name, as coop.lua takes one back, and unregistered. One that's gone has its bar, if the
    -- HUD still shows it, collapsed. fname, cname: the figure's name and its class's; hud: this tick's, or nil.
    function game.dropFoeBar(addr, fname, cname, hud)
        local want = addr and foeBars[addr]
        if not want then
            return
        end
        foeBars[addr] = nil
        hud = valid(hud) and hud or FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            return          -- (no HUD, mid-load: its bars went with it)
        end
        for _, a in ipairs((cname and FindAllOf(cname)) or {}) do
            if valid(a) and a:GetAddress() == addr and a:GetFName():ToString() == fname then
                pcall(function() hud:UnRegisterBossHPBar(a) end)
                return
            end
        end
        if type(want) == "number" then
            for _, bar in ipairs(bossBarList(hud)) do
                if bar:GetAddress() == want then
                    pcall(function() bar:SetVisibility(1) end)
                end
            end
        end
    end

    -- The gold posture strip under its health (BreakmeterBar), moved by the bar's own ForSeq_UpdateShachi: a figure's bar
    -- has no Character, so nothing of the game's moves it, and unfed it stood full all match. share: the foe's posture as a
    -- share of its top, or nil when it isn't known here: the strip hidden (hidden, not collapsed: the bar keeps its shape).
    -- False if there's no bar.
    function game.setFoeShachi(addr, share, hud)
        local bar = game.foeBar(addr, hud)
        if not bar then
            return false
        end
        local strip = nil
        pcall(function() strip = bar.BreakmeterBar end)
        if valid(strip) then
            pcall(function() strip:SetVisibility(share and 3 or 2) end)
        end
        if share then
            pcall(function() bar:ForSeq_UpdateShachi(math.max(0, math.min(1, share))) end)
        end
        return true
    end

    -- The bar breaking as a boss's posture does: the game's own animation and its sparks (NS_UI_ShaChiBar_Break_001),
    -- for a PvP match's deciding blow. (Its posture strip shown first: hidden for want of a value, it broke unseen.)
    function game.breakFoeBar(addr)
        local bar = game.foeBar(addr)
        if bar then
            pcall(function()
                local strip = bar.BreakmeterBar
                if valid(strip) then
                    strip:SetVisibility(3)
                end
            end)
            pcall(function() bar:PlayAnimation(bar.ShachiEmpty, 0, 1, 0, 1, false) end)
            pcall(function() bar.NS_UI_ShaChiBar_Break_001:ActivateSystem(true) end)
        end
        return bar ~= nil
    end

    -- One of the game's own sounds (a Wwise event: path "/Game/Wwise/Events/.../Name"), played on an actor: its music's
    -- stingers, its UI's. Loaded when first wanted (not just after a load: the world's quiet, as for searches). The
    -- playing id, or nil.
    function game.playSound(path, actor)
        if not (path and valid(actor)) or os.clock() < ((api.coop and api.coop.net.quietUntil) or 0) then
            return nil
        end
        local name = path:match("([^/]+)$")
        local full = path .. "." .. name
        local ev = StaticFindObject(full)
        if not valid(ev) and type(LoadAsset) == "function" then
            pcall(LoadAsset, path)
            ev = StaticFindObject(full)
        end
        local lib = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
        if not (valid(ev) and valid(lib)) then
            return nil
        end
        local ok, id = pcall(function() return lib:PostEvent(ev, actor, 0, {}, false) end)
        return ok and id or nil
    end

    -- Arabic: none of the game's fonts has Arabic letters (bench 11-10: its tips dropped them, Roboto drew boxes), but the
    -- engine's own Arabic font is in its files. Made Roboto's fallback face (in place of DroidSansFallback, the Chinese one,
    -- so in Arabic only), any text in Roboto draws Arabic, joined and right to left (bench, the same day). Once, and as
    -- early as can be: the game keeps a fallback it has used. True once it's in.
    game.ARABIC_TTF = "../../../Engine/Content/Slate/Fonts/NotoNaskhArabicUI-Regular.ttf"
    game.ARABIC_FONT = "/Engine/EngineFonts/Roboto.Roboto"
    function game.arabicFont()
        if game.arabicDone ~= nil then
            return game.arabicDone
        end
        local font = StaticFindObject(game.ARABIC_FONT)
        if not valid(font) then
            return false        -- (not loaded yet: asked again next time)
        end
        local entry
        pcall(function()
            font.CompositeFont.FallbackTypeface.Typeface.Fonts:ForEach(function(_, e)
                if entry == nil then
                    entry = e:get()
                end
            end)
        end)
        local ok, err = false, "Roboto has no fallback face"
        if entry ~= nil then
            ok, err = pcall(function()
                entry.Font.FontFilename = game.ARABIC_TTF
                entry.Font.LoadingPolicy = 0        -- (LazyLoad: read from the file the first time it's drawn)
                entry.Font.FontFaceAsset = nil
            end)
        end
        game.arabicDone = ok
        log(ok and "Arabic: the engine's Arabic font is in (Roboto's fallback)." or ("Arabic: no Arabic font: " .. tostring(err)))
        return ok
    end

    -- A TextBlock in Roboto, for Arabic. pt: points, or its own size. One of the game's own (a foe's bar) keeps a note of
    -- its own font, as plain words by its address, to have it back after a switch from Arabic (game.ownText): Roboto's
    -- fallback is Arabic then, so Chinese in it drew boxes (the review, 11-10).
    local ownFonts = {}         -- TextBlock address -> { path, face, size } of its own font
    local function fontPath(font)
        return (font:GetFullName():gsub("^%S+ ", ""))
    end
    function game.arabicText(tb, pt)
        local roboto = game.arabicFont() and StaticFindObject(game.ARABIC_FONT)
        if not (valid(tb) and valid(roboto)) then
            return false
        end
        return pcall(function()
            local f = tb.Font
            local was = valid(f.FontObject) and fontPath(f.FontObject)
            if was == fontPath(roboto) and (not pt or f.Size == pt) then
                return                                      -- (already: the foe's label comes every second)
            end
            local addr = tb:GetAddress()
            if was and was ~= fontPath(roboto) and not ownFonts[addr] then
                ownFonts[addr] = { path = was, face = f.TypefaceFontName:ToString(), size = f.Size }
            end
            f.FontObject = roboto
            f.TypefaceFontName = FName("Regular")
            if pt then
                f.Size = pt
            end
            tb:SetFont(f)
        end)
    end

    -- Its own font back on a TextBlock game.arabicText put in Roboto, if it noted one.
    function game.ownText(tb)
        local own = valid(tb) and ownFonts[tb:GetAddress()]
        if not own then
            return false
        end
        ownFonts[tb:GetAddress()] = nil
        return pcall(function()
            local font = StaticFindObject(own.path)
            if valid(font) then
                local f = tb.Font
                f.FontObject = font
                f.TypefaceFontName = FName(own.face)
                f.Size = own.size
                tb:SetFont(f)
            end
        end)
    end

    -- The ink-bar tip (WB_TipsText, status.newTipWidget) saying an Arabic line. Its rich text (the game's
    -- PBZCommonLocRichText) keeps to the game's own fonts whatever its default font is set to (bench 11-10: Roboto set,
    -- the Arabic still dropped), so the line goes in a TextBlock of the mod's beside it, in Roboto, and the rich text
    -- (holding the English, for the bar's size) is hidden but still laid out. text nil: the game's own text again (a
    -- language switch). (Only the tip's class has ItemText: UE4SS answers a name on any class, so only ever a tip here.)
    -- wrap: the width its lines wrap at (slate units, 1920 across a 16:9 screen), the tip's own 1700 if not given: the
    -- longest lines ran off the screen in one line (as the English does; bench 11-10). It's read when the text is first
    -- made, so a widget keeps the first it's given.
    -- (An Arabic line goes in after a right-to-left mark: one starting with an English word, "Steam ...", was laid out
    -- left to right, its Arabic in the wrong order. Not one left English: its full stop went to the left. The mark isn't
    -- drawn; bench 11-10.)
    game.ARABIC_TIP = "PPArabicTip"
    game.RLM = "\226\128\143"
    function game.arabicTip(tip, text, pt, wrap)
        if not valid(tip) then
            return false
        end
        return pcall(function()
            local rich = tip.ItemText
            local parent = valid(rich) and rich:GetParent()
            if not valid(parent) then
                return
            end
            local tb
            for i = 0, parent:GetChildrenCount() - 1 do
                local c = parent:GetChildAt(i)
                if valid(c) and c:GetFName():ToString() == game.ARABIC_TIP then
                    tb = c
                end
            end
            if text == nil then
                if tb then
                    tb:SetVisibility(1)                             -- collapsed
                    rich:SetVisibility(game.tipRichVisibility or 4)
                end
                return
            end
            local roboto = game.arabicFont() and StaticFindObject(game.ARABIC_FONT)
            if not valid(roboto) then
                return
            end
            local made = not tb
            if made then
                tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tip.WidgetTree, FName(game.ARABIC_TIP))
                tb.WrapTextAt = wrap or 1700                        -- (before it's added: it has no setter)
                tb.AutoWrapText = false                             -- (on, it wrapped at the hidden English's width)
                local slot = parent:AddChild(tb)
                slot:SetHorizontalAlignment(2)                      -- centred, as the game's line
                slot:SetVerticalAlignment(2)
                tb:SetJustification(1)
                tb:SetColorAndOpacity({ SpecifiedColor = { R = 0.92, G = 0.89, B = 0.84, A = 1.0 }, ColorUseRule = 0 })
            end
            local f = tb.Font
            if made or (pt and f.Size ~= pt) then               -- (a new TextBlock is in Roboto already, but bold 24)
                f.FontObject = roboto
                f.TypefaceFontName = FName("Regular")
                f.Size = pt or 20
                tb:SetFont(f)
            end
            tb:SetText(FText((text:find("[\216-\219]") and game.RLM or "") .. text))     -- (Arabic letters: UTF-8 D8-DB ..)
            tb:SetVisibility(4)                                     -- seen, never clicked
            local v = rich:GetVisibility()
            if v ~= 2 then
                game.tipRichVisibility = v
            end
            rich:SetVisibility(2)                                   -- hidden, still laid out
            game.arabicTipUsed = true
        end)
    end

    -- The bar of a fight that ended without the game saying so (the other PC's boss, a refresh).
    function game.hideBossBar(boss)
        local hud = FindFirstOf("PBZHUDLayout")
        if valid(boss) and valid(hud) then
            pcall(function() hud:UnRegisterBossHPBar(boss) end)
            forgetBoss(boss)
        end
    end

    -- Boss arenas are sealed by fog walls (BP_FogDoor_C). When the other player's boss fight starts, close the
    -- fog walls near our copy of the boss; when the boss dies, open them. at: where the boss stands (it may be gone
    -- by the time the walls open).
    local FOG_RADIUS_CM = 6000
    -- quiet: no line in the log (a PvP match closes them again every second).
    function game.setBossFog(at, closed, quiet)
        local n = 0
        for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            -- (By the wall's nearest point, not the actor: that stands at the wall's first point, up to 50 m from the rest.)
            local ok, loc = pcall(function() return door.Spline:FindLocationClosestToWorldLocation(at, 1) end)
            if not (ok and loc and loc.X) then
                ok, loc = pcall(function() return door:K2_GetActorLocation() end)
            end
            if ok and loc.X and distance(loc, at) <= FOG_RADIUS_CM then
                local fn = closed and "Close By Mob Script" or "OpenByMobScript"
                if pcall(function() door[fn](door) end) then
                    n = n + 1
                end
            end
        end
        if n > 0 and not quiet then
            log(string.format("%s %d fog wall(s) at %.0f %.0f.", closed and "Closed" or "Opened", n, at.X, at.Y))
        end
        return n
    end

    -- A fog wall is a spline (the actor stands at its first point, up to 50 m from the far end) laid along the ground,
    -- with spline meshes that block only while the wall is up: collision 3 closed, 0 open (read on A-Hua's walls).
    -- (Kept in one table: this file is at the 200 locals a function may have.)
    -- pass: how far past the wall; fall: a drop this big after it means no floor; watch: for this long.
    local FOG = { MESH = "/Script/Engine.SplineMeshComponent", PASS_CM = 300, FALL_CM = 400, WATCH_S = 2.0 }
    function FOG.closed(door)
        local closed = false
        pcall(function()
            local meshes = door:K2_GetComponentsByClass(StaticFindObject(FOG.MESH))
            for i = 1, #meshes do
                if meshes[i]:get():GetCollisionEnabled() ~= 0 then
                    closed = true
                    return
                end
            end
        end)
        return closed
    end

    -- The closed fog wall nearest a spot, within `within` of it along the ground: { at = nearest point on the wall,
    -- normal = across the wall, flat }, or nil.
    function game.closedFogNear(spot, within)
        local best, bestGap = nil, within
        for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            local ok, at, right = pcall(function()
                local s = door.Spline
                return s:FindLocationClosestToWorldLocation(spot, 1), s:FindRightVectorClosestToWorldLocation(spot, 1)
            end)
            local gap = ok and at.X and math.sqrt((at.X - spot.X) ^ 2 + (at.Y - spot.Y) ^ 2)
            -- (Its line can lie well under the floor, the wall rising from it: Lei Dang's, 8 m under it on both sides, was
            -- never found at 6 m, and E did nothing there. Up to 15 m under the player, 6 m over.)
            local dz = gap and (at.Z - spot.Z)
            if gap and gap <= bestGap and dz < 600 and dz > -1500 and FOG.closed(door) then
                local len = math.sqrt(right.X ^ 2 + right.Y ^ 2)
                if len > 0.1 then
                    best, bestGap = { at = { X = at.X, Y = at.Y, Z = at.Z }, normal = { X = right.X / len, Y = right.Y / len } }, gap
                end
            end
        end
        return best
    end

    -- Which side of that wall a spot is on: + or -, by the distance across it.
    function game.fogSide(wall, spot)
        return (spot.X - wall.at.X) * wall.normal.X + (spot.Y - wall.at.Y) * wall.normal.Y
    end

    -- Whether there's floor under a spot: the player is put there and swept straight down, all in this frame. Stopped by
    -- something on the way, that's where they stand; through the whole drop, or not moved at all (in a wall), it's no place.
    -- Never over a drop to find out: a doorway at Zhengdaodaying has one 3 m past it, and the player fell for 0.6 s
    -- before the watch below put them back.
    FOG.PROBE_CM = 450
    FOG.TRY_CM = { 300, 200, 450, 600, 120 }
    FOG.BESIDE = { { 250, 0 }, { -250, 0 }, { 0, 250 }, { 0, -250 }, { 150, 150 }, { -150, -150 }, { 0, 0 } }
    function FOG.floorAt(pawn, spot)
        pawn:K2_SetActorLocation(spot, false, {}, true)
        pawn:K2_SetActorLocation({ X = spot.X, Y = spot.Y, Z = spot.Z - FOG.PROBE_CM }, true, {}, false)
        local z = pawn:K2_GetActorLocation().Z
        return z < spot.Z - 2 and z > spot.Z - FOG.PROBE_CM + 2
    end

    -- Through the wall to the side `toward` is on (the fight's side), a few metres past it, onto floor found first. Nil,
    -- and the player left where they are, if there's none. It's walked, as a Souls wall is: the player walks into it, is
    -- across the moment they reach it (or after WALK_S), and walks on a moment there. A drop in the next moments still
    -- sends them back.
    FOG.WALK_S = 0.7                -- longest walk up to the wall
    FOG.ON_S = 0.4                  -- and on, past it
    FOG.REACH_CM = 90               -- this close to the wall counts as reaching it
    function game.passFog(pawn, wall, toward)
        local from = pawn:K2_GetActorLocation()
        local side = game.fogSide(wall, toward) >= 0 and 1 or -1
        local spot = nil
        pawn.CharacterMovement:SetMovementMode(5, 0)        -- (flying for the sweeps: nothing pulls them down meanwhile)
        for _, cm in ipairs(FOG.TRY_CM) do
            local try = {
                X = wall.at.X + wall.normal.X * cm * side,
                Y = wall.at.Y + wall.normal.Y * cm * side,
                Z = math.max(wall.at.Z, from.Z) + 150,
            }
            if FOG.floorAt(pawn, try) then
                spot = pawn:K2_GetActorLocation()
                break
            end
        end
        -- None past the wall (a ledge, stairs, a drop behind the doorway): beside the one inside instead, who stands on the
        -- floor of the fight, a few metres off them. (The user's worry: one wall without floor past it and the other player
        -- could never get in.)
        for _, off in ipairs(spot and {} or FOG.BESIDE) do
            local try = { X = toward.X + off[1], Y = toward.Y + off[2], Z = toward.Z + 150 }
            if FOG.floorAt(pawn, try) then
                spot = pawn:K2_GetActorLocation()
                log("No floor just past the fog wall: across it to beside the other player.")
                break
            end
        end
        if not spot then
            pawn:K2_SetActorLocation(from, false, {}, true)
            pawn.CharacterMovement:SetMovementMode(1, 0)
            log("No floor past the fog wall here: the player stays where they are.")
            return nil
        end
        spot = { X = spot.X, Y = spot.Y, Z = spot.Z }
        pawn:K2_SetActorLocation(from, false, {}, true)     -- (back for the walk up to it)
        pawn.CharacterMovement:SetMovementMode(1, 0)
        local into = { X = wall.normal.X * side, Y = wall.normal.Y * side, Z = 0 }
        local started, acrossAt = os.clock(), nil
        local function watch()
            if not valid(pawn) or game.isDead(pawn) then
                return
            end
            if pawn:K2_GetActorLocation().Z < spot.Z - FOG.FALL_CM then
                log("No floor past the fog wall: back where the player pressed.")
                pawn:K2_SetActorLocation({ X = from.X, Y = from.Y, Z = from.Z + 30 }, false, {}, true)
                return
            end
            if os.clock() - acrossAt < FOG.WATCH_S then
                game.after(0.1, watch)
            end
        end
        local function walk()
            if not valid(pawn) or game.isDead(pawn) then
                return
            end
            local now = os.clock()
            if not acrossAt then
                local gap = math.abs(game.fogSide(wall, pawn:K2_GetActorLocation()))
                if gap <= FOG.REACH_CM or now - started >= FOG.WALK_S then
                    pawn:K2_SetActorLocation(spot, false, {}, true)
                    acrossAt = now
                    log(string.format("Through the fog wall: %.0f %.0f %.0f.", spot.X, spot.Y, spot.Z))
                    game.after(0.1, watch)
                end
            elseif now - acrossAt >= FOG.ON_S then
                return
            end
            pcall(function() pawn:AddMovementInput(into, 1.0, true) end)
            game.after(0.02, walk)
        end
        walk()
        return spot
    end

    -- fog: test helper, list fog walls with distance to player 1 and their state.
    game.commands.fog = function()
        local _, pawn = api.getPlayer1()
        local here = pawn:K2_GetActorLocation()
        for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            local st = "?"
            pcall(function() st = tostring(door.bDesiredState) end)
            log(string.format("  %s desired=%s %.0f m", door:GetFName():ToString():sub(-24), st,
                distance(door:K2_GetActorLocation(), here) / 100))
        end
    end

    -- bossbar: test helper, start the boss bar for the nearest boss as if its fight began.
    game.commands.bossbar = function()
        for _, e in ipairs(game.listEnemies()) do
            if game.isBoss(e) and not game.isDead(e) then
                local hud = FindFirstOf("PBZHUDLayout")
                if not valid(hud) then
                    log("No HUD layout.")
                    return
                end
                local ok, err = pcall(function() hud:RegisterBossHPBar(e) end)
                log("RegisterBossHPBar(" .. e:GetFName():ToString() .. "): " .. tostring(ok) .. " " .. tostring(err))
                return
            end
        end
        log("No living boss loaded.")
    end

    -- Note: APBZCharacter::OnDamage looked like the place to catch hits, but PBZ calls it natively and a UE4SS
    -- hook never fires, so coop.lua detects hits by watching health and posture drop instead.

    ------------------------------------------------------------------ moves (attacks, dodges, parries)

    -- pcall: for a frame while the game swaps the player (loading, respawn) this call failed once with "UFunction
    -- expected 1 parameters, received 3"; no ability system this tick, try again next one.
    local function abilitySystem(actor)
        local bl = lib("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        if not valid(bl) or not valid(actor) then
            return nil
        end
        local ok, asc = pcall(function() return bl:GetAbilitySystemComponent(actor) end)
        return (ok and valid(asc)) and asc or nil
    end

    local function forEachSpec(asc, fn)
        local ok = pcall(function()
            asc.ActivatableAbilities.Items:ForEach(function(_, elem)
                fn(elem:get())
            end)
        end)
        return ok
    end

    local activeLocal = {}        -- ability class path -> true while active on the local player
    local localMoveAt, ghostMoveAt = -1e9, -1e9   -- os.clock() when the local player / the ghost last started a move

    -- An item in use (the gourd, a medicine) shows effects on the player's body from the item's own ability, which the
    -- ghost doesn't run: the drinking it shows is the animation alone. Each effect that appears on the body while an item
    -- is in use is sent (FX) and put on the ghost's. Those already there, and footsteps (the ghost makes its own), aren't.
    local itemFx = { FOR_S = 3.0, untilAt = -1e9, using = false, seen = {} }

    function itemFx.isUse(name)
        return (name:find("^GA_Medicine") ~= nil or name:find("^GA_Item") ~= nil or name:find("^GA_Use") ~= nil)
            and name:find("Passive") == nil
    end

    function itemFx.scan(pawn, sendEvent)
        pcall(function()
            local niagara = StaticFindObject("/Script/Niagara.NiagaraComponent")
            if not (valid(niagara) and pawn:IsA(StaticFindObject("/Script/Engine.Character"))) then
                return
            end
            local mesh = pawn.Mesh
            for i = 0, mesh:GetNumChildrenComponents() - 1 do
                local c = mesh:GetChildComponent(i)
                if valid(c) and not itemFx.seen[c:GetAddress()] and c:IsA(niagara) and c:IsActive() then
                    itemFx.seen[c:GetAddress()] = true
                    local path = c:GetAsset():GetFullName():gsub("^%S+ ", "")
                    if sendEvent and not path:find("FootStep") then
                        sendEvent("FX", path, c:GetAttachSocketName():ToString())
                    end
                end
            end
        end)
    end

    -- Who caused an enemy's health drop: the local player's swing (a real hit to report) or the ghost's replay
    -- of the other player's swing (that hit is the other PC's, already reported there: counting it here would
    -- double it).
    function game.localMoveRecent(seconds)
        return os.clock() - localMoveAt <= seconds
    end

    function game.ghostMoveRecent(seconds)
        return os.clock() - ghostMoveAt <= seconds
    end

    -- The ghost started one of the partner's moves some other way (a montage, moves.lua): don't steer it while
    -- the move's own motion plays, and count it for the hit attribution above. seconds: how long it isn't steered (a
    -- PvP finishing move: all of it).
    function game.noteGhostMove(ghost, seconds)
        holdGhost(ghost, seconds)
        ghostMoveAt = os.clock()
    end

    -- Called every snapshot: any GA_* ability that just became active on the local player is sent as a move.
    -- The local player started something (a montage, moves.lua): counts for the hit attribution above.
    function game.noteLocalMove()
        localMoveAt = os.clock()
    end

    -- A move, by its ability's class name: Hun's own (GA_Hun_Young_A, ..._AdvancedDash, ...), not a passive. A passive is
    -- equipment's always-on part, not something the player did: a match's Phantom Edges turn theirs on as it's set up,
    -- they went as moves, and the other world gave one to the player's figure and started it there, where it called into
    -- nothing (the bench, 11-07: GA_Hun_ShachiHook_Passive_C, then a guest's game gone at PBZ.exe+0x153e1a6, a call to 0).
    -- A Phantom Edge's own too: its skills are GA_<edge>_* (GA_BrutalAxe_Normal_C, GA_TigerCannon_Dash_C), not Hun's, so
    -- one was never sent, a foe's figure never played it, and its blow never landed in a match (the bench, 11-08). Known by
    -- the edges the game has (arenas.lua's list, kept in game.edgeWords); never an execution (it needs a victim the other
    -- world hasn't).
    function game.isMoveName(name)
        if name:find("Passive", 1, true) then
            return false
        end
        if name:find("^GA_Hun") then
            return true
        end
        local words = game.edgeWords
        if not words and api.arenaData then
            words = {}
            for _, e in ipairs(api.arenaData.edges or {}) do
                words[e.id] = true
            end
            game.edgeWords = words
        end
        local word = words and name:match("^GA_(%w+)_")
        return word ~= nil and words[word] == true and name:find("Execution", 1, true) == nil
    end

    -- A guard's answer to a blow, by its montage's name or path: the game plays Hun_<weapon>_DefenceNormal_* for a deflect
    -- and for a block alike (the bench, 11-07). Not the stance's own enter and exit. (pvp.lua judges a parry by it; moves.lua
    -- sends it in a match.)
    function game.isGuardReaction(name)
        return name ~= nil and name:find("Defence", 1, true) ~= nil and name:find("Stance", 1, true) == nil
    end

    -- The guard's own montages: its answer to a blow (above) and the stance itself (AM_Hun_<weapon>_StanceEnter, _StanceExit).
    -- A figure can't start the stance's ability ("Ghost couldn't play GA_Hun_Tang_Stance_C", every time on the bench), so in a
    -- match these go as montages (moves.lua): before, a guard raised was never seen by the other side at all.
    function game.isGuardMove(name)
        return name ~= nil and (name:find("Defence", 1, true) ~= nil or name:find("Stance", 1, true) ~= nil)
    end

    function game.watchLocalPlayer(pawn, sendEvent)
        local asc = abilitySystem(pawn)
        if not asc then
            return
        end
        -- The same move started again while it still ran (a swing in the last one's recovery): the game restarts its
        -- ability, which never stops being active, so only its montage starting over from its beginning tells. Told again
        -- then, but for the guard's (a figure can't start the stance). A player's report, 11-09: a foe's pokes a couple of
        -- seconds apart went unseen on its figure but for the ones after a blow of theirs, the pokes' blows landing all
        -- the same. (The montage by address and position: nothing kept across frames.)
        local again = false
        pcall(function()
            local ai = pawn.Mesh:GetAnimInstance()
            local m = ai:GetCurrentActiveMontage()
            local addr = valid(m) and m:GetAddress() or nil
            local pos = addr and ai:Montage_GetPosition(m) or 0
            local was = game.ownMontage
            again = addr ~= nil and was ~= nil and was.addr == addr and pos < 0.15 and was.pos > 0.35
            if addr then
                game.ownMontage = was or {}
                game.ownMontage.addr, game.ownMontage.pos = addr, pos
            else
                game.ownMontage = nil
            end
        end)
        local nowActive = {}
        forEachSpec(asc, function(spec)
            -- (The ability read only for a running one: a wrapper made for each of a couple of hundred, every frame in a
            -- match, was most of the walk's cost; the review of 1.7.0.)
            local ability = spec.ActiveCount > 0 and spec.Ability
            if ability and valid(ability) then
                local cls = ability:GetClass()
                local name = cls:GetFName():ToString()
                -- Only Hun's own moves; background abilities such as GA_LocomotionDriver_3DDefault and the
                -- passives are always active and aren't moves.
                if game.isMoveName(name) then
                    local path = cls:GetFullName():gsub("^%S+ ", "")
                    nowActive[path] = true
                    if not activeLocal[path] or (again and not game.isGuardMove(name)) then
                        -- The facing at the start of the move, so the ghost swings where the player aimed.
                        sendEvent("M", path, string.format("%.1f", pawn:K2_GetActorRotation().Yaw))
                        localMoveAt = os.clock()
                        if name:find("Stance", 1, true) then
                            -- (pvp.lua: a parry is a guard raised to meet the blow; the press before it tells a click that
                            -- met nothing from one that met a blow.)
                            game.guardPrevAt, game.guardUpAt = game.guardUpAt, localMoveAt
                        end
                    end
                end
            end
        end)
        activeLocal = nowActive
    end

    -- How this player moves: "w" walking, "j" jogging, "s" sprinting, as their animation blueprint has it (a blueprint of
    -- another kind is read as jogging: its fields aren't these).
    function game.gait(pawn)
        local g = "j"
        pcall(function()
            local ai = pawn.Mesh:GetAnimInstance()
            if ai:GetClass():GetFName():ToString():find("^PBZ_ABP_Hun") then
                g = ai.GameplayTag_IsSprint == true and "s" or ai["Gameplay Tag Run"] == true and "j" or "w"
            end
        end)
        return g
    end

    -- How the ghost moves: walking, jogging or sprinting, as the partner does. Its own locomotion takes that from the
    -- stick, and a ghost has none: it jogged at any speed (a walk was a slow jog, a sprint a fast one). Its state is
    -- switched the game's way (ActorStateComponent:TryActivateNewState), with a tag of the game's own: the one its
    -- locomotion keeps as its default, renamed (a tag built here took the game down). True when the game took it.
    local GAITS = { w = "CharacterState.Native.Attitude.Walking", j = "CharacterState.Native.Attitude.Jogging",
        s = "CharacterState.Native.Attitude.Sprinting" }
    function game.setGhostGait(ghost, gait)
        local tag, asc = GAITS[gait], abilitySystem(ghost)
        if not (tag and asc) then
            return false
        end
        local driver = nil
        forEachSpec(asc, function(spec)
            pcall(function()
                if spec.Ability:GetClass():GetFName():ToString():find("LocomotionDriver") then
                    spec.NonReplicatedInstances:ForEach(function(_, i) driver = i:get() end)
                end
            end)
        end)
        if not valid(driver) then
            return false            -- (none, or one gone: written through before this was asked)
        end
        local ok, took = pcall(function()
            driver.DefaultAttitudeStateTag.TagName = FName(tag)
            return driver.ActorStateComponent:TryActivateNewState(driver.DefaultAttitudeStateTag)
        end)
        return ok and took == true
    end

    -- Whether this player holds a guard stance (the right button): its ability runs as long as it's held.
    function game.inStance(pawn)
        local asc, on = abilitySystem(pawn), false
        if asc then
            forEachSpec(asc, function(spec)
                if not on and (tonumber(spec.ActiveCount) or 0) > 0 then
                    local ok, name = pcall(function() return spec.Ability:GetClass():GetFName():ToString() end)
                    on = ok and name:find("^GA_Hun_.*_Stance_C$") ~= nil
                end
            end)
        end
        return on
    end

    -- Ten times a second, co-op or PvP: an item coming into use, and the effects it puts on the body for a while. True as a
    -- drink from the gourd starts.
    function game.watchItemFx(pawn, sendEvent)
        local asc = abilitySystem(pawn)
        if not asc then
            return false
        end
        local using, drink = false, false
        forEachSpec(asc, function(spec)
            if not using and (tonumber(spec.ActiveCount) or 0) > 0 then
                local ok, name = pcall(function() return spec.Ability:GetClass():GetFName():ToString() end)
                using = ok and itemFx.isUse(name)
                drink = using and name:find("^GA_Medicine") ~= nil
            end
        end)
        local drinkStarts = drink and not itemFx.using
        -- (The window shuts half a second after the item's use ends, 3 s at most: a skill's or a dodge's effect on the body
        -- just after a drink went out as the drink's, and looped on the figure.)
        if itemFx.using and not using then
            itemFx.untilAt = math.min(itemFx.untilAt, os.clock() + 0.5)
        end
        if using and not itemFx.using then
            itemFx.seen, itemFx.untilAt = {}, os.clock() + itemFx.FOR_S
            itemFx.scan(pawn, nil)          -- (what's on the body already isn't the item's)
        elseif os.clock() < itemFx.untilAt then
            itemFx.scan(pawn, sendEvent)
        end
        itemFx.using = using
        return drinkStarts
    end

    -- Replays the remote player's move on the ghost. Gives the ability first if the ghost lacks it.
    local loadTried = {}          -- class path -> true once we tried loading it (a failed load isn't retried)
    function game.playMove(ghost, classPath, yaw)
        -- (A path off the wire: an asset path's shape only, as playAbility asks; and only ever an ability class below.)
        if type(classPath) ~= "string" or #classPath > 256 or not classPath:match("^/[%w_/%-]+%.[%w_%-]+$") then
            return
        end
        -- (Never a passive, whoever sent it: started on a figure, one took the game down. isMoveName says why.)
        if (classPath:match("([^.]+)$") or ""):find("Passive", 1, true) then
            return
        end
        local cls = StaticFindObject(classPath)
        if not valid(cls) and not loadTried[classPath] and type(LoadAsset) == "function" then
            -- A move of a weapon the local player doesn't carry isn't in memory yet (other weapons, Phantom Edge).
            loadTried[classPath] = true
            pcall(LoadAsset, classPath)
            cls = StaticFindObject(classPath)
        end
        if not valid(cls) then
            log("Move class not loaded here: " .. classPath)
            return
        end
        if not game.isAbilityClass(cls, classPath) then
            return
        end
        local asc = abilitySystem(ghost)
        if not asc then
            return
        end
        -- The same move again while the figure's copy of the last one still runs (told again as it starts over: see
        -- watchLocalPlayer): that one is cancelled first, as the player's own game restarts it. Refused as already active,
        -- the new one never played (a player's report, 11-09).
        local name, running = cls:GetFName():ToString(), {}
        forEachSpec(asc, function(spec)
            if (tonumber(spec.ActiveCount) or 0) > 0 then
                pcall(function()
                    if spec.Ability:GetClass():GetFName():ToString() == name then
                        for _, list in ipairs({ spec.NonReplicatedInstances, spec.ReplicatedInstances }) do
                            pcall(function()
                                list:ForEach(function(_, i)
                                    running[#running + 1] = i:get()
                                end)
                            end)
                        end
                    end
                end)
            end
        end)
        for _, inst in ipairs(running) do
            if valid(inst) then
                pcall(function() inst:K2_CancelAbility() end)
            end
        end
        -- (A yaw off the wire: "nan" and "1e999" read as numbers, and went into the ghost's rotation.)
        if yaw and not (yaw == yaw and math.abs(yaw) <= 720) then
            yaw = nil
        end
        if yaw then
            pcall(function() ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false) end)
            game.lastMoveYaw = yaw
        end
        local ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
        if not (ok and activated) then
            -- Given only if it isn't there: refused again (the guard's stance always is, on a figure), another copy went on
            -- each time and the figure's list grew all match (the bench, 11-07: three of the stance after two guards).
            local name, has = cls:GetFName():ToString(), false
            forEachSpec(asc, function(spec)
                if not has then
                    local okn, n = pcall(function() return spec.Ability:GetClass():GetFName():ToString() end)
                    has = okn and n == name
                end
            end)
            if not has then
                pcall(function() asc:K2_GiveAbility(cls, 1, -1) end)
                ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
            end
        end
        -- Their own game let them move, so the figure's flinch from a blow here (for show only: theirs decides) goes first.
        -- A dodge begun as the blow came was refused on a flinching figure, and the blow seemed to land (the bench, 11-07).
        if not (ok and activated) and game.hitStateOf then
            local state = game.hitStateOf(ghost)
            if state and state ~= "None" then
                game.clearHitState(ghost)
                pcall(function()
                    local ai = ghost.Mesh:GetAnimInstance()
                    local cur = valid(ai) and ai:GetCurrentActiveMontage()
                    if valid(cur) then
                        ai:Montage_Stop(0.1, cur)
                    end
                end)
                ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
            end
        end
        holdGhost(ghost)            -- (each ghost of a party its own: one timer for all held every other ghost too)
        ghostMoveAt = os.clock()
        if not (ok and activated) and not loadTried["refused " .. classPath] then
            loadTried["refused " .. classPath] = true       -- (once a move: the guard's stance is refused every time)
            log("Ghost couldn't play " .. classPath:match("([^.]+)$"))
        end
    end

    -- An effect the partner's item showed on their body (FX), on the ghost's: the same system, on the same socket. Some loop
    -- (the gourd's green glow): on the partner the drink's own effect ends them, which a ghost hasn't got, so each drink's
    -- stayed on for good, stacking, the frame rate lower with each (a player report, 11-06). Each now goes after
    -- itemFx.GHOST_S, and a new one of the same system takes the old one's place.
    -- (On itemFx, not locals: this function is at the 200 Lua allows.)
    -- Each is found again on the figure by its system when it's time, the figure by its address among the partners': no
    -- component is kept for those 8 s (a one-shot copy destroys itself in a second or two, and a kept pointer to it is
    -- what UE4SS can't check; the review of the player-report fixes).
    itemFx.GHOST_S, itemFx.onGhost = 8, {}      -- ghost address .. path -> { addr, path, at }
    function itemFx.endOnGhost(key)
        local f = itemFx.onGhost[key]
        itemFx.onGhost[key] = nil
        if not f then
            return
        end
        for _, p in ipairs(api.coop and api.coop.partners() or {}) do
            if valid(p.ghost) and p.ghost:GetAddress() == f.addr then
                pcall(function()
                    local mesh = p.ghost.Mesh
                    local niagara = StaticFindObject("/Script/Niagara.NiagaraComponent")
                    for i = mesh:GetNumChildrenComponents() - 1, 0, -1 do
                        local c = mesh:GetChildComponent(i)
                        if valid(c) and c:IsA(niagara) then
                            local a = c:GetAsset()
                            if valid(a) and a:GetFullName():gsub("^%S+ ", "") == f.path then
                                c:Deactivate()      -- (it fades out and goes: it was made to destroy itself)
                            end
                        end
                    end
                end)
            end
        end
    end
    function game.ghostEffect(ghost, path, socket)
        if not (path:match("^/[%w_/%-]+%.[%w_%-]+$") and #path <= 200 and socket:match("^[%w_]+$")) then
            return false
        end
        local sys = StaticFindObject(path)
        if not valid(sys) and not loadTried[path] and type(LoadAsset) == "function" then
            loadTried[path] = true
            pcall(LoadAsset, path)
            sys = StaticFindObject(path)
        end
        local addr = ghost:GetAddress()
        local key = tostring(addr) .. path
        itemFx.onGhost[key] = itemFx.onGhost[key] or { addr = addr, path = path }
        itemFx.endOnGhost(key)          -- (the old one's place: a new one of the same system takes it)
        return (pcall(function()
            if valid(sys) and sys:IsA(StaticFindObject("/Script/Niagara.NiagaraSystem"))
                and ghost:IsA(StaticFindObject("/Script/Engine.Character")) then
                local comp = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary"):SpawnSystemAttached(sys,
                    ghost.Mesh, FName(socket), { X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, 0, true, true,
                    0, true)
                if valid(comp) then
                    local f = { addr = addr, path = path }
                    itemFx.onGhost[key] = f
                    game.after(itemFx.GHOST_S, function()
                        if itemFx.onGhost[key] == f then
                            itemFx.endOnGhost(key)
                        end
                    end)
                end
            end
        end))
    end

    -- The class path of the first running ability that isn't passive(name), or nil.
    function game.activeAbility(actor, passive)
        local asc = abilitySystem(actor)
        local found = nil
        if asc then
            pcall(function()
                asc.ActivatableAbilities.Items:ForEach(function(_, spec)
                    -- Own pcall: an error must never unwind through UE4SS's ForEach.
                    pcall(function()
                        local s = spec:get()
                        if s.ActiveCount > 0 then
                            local path = s.Ability:GetClass():GetFullName():gsub("^%S+ ", "")
                            if not passive(path) then
                                found = path    -- the last: a move made of steps runs each as an ability of its own, given later
                            end
                        end
                    end)
                end)
            end)
        end
        return found
    end

    local function hasAbility(asc, cls)
        local name, has = cls:GetFName():ToString(), false
        pcall(function()
            asc.ActivatableAbilities.Items:ForEach(function(_, spec)
                pcall(function()
                    if spec:get().Ability:GetClass():GetFName():ToString() == name then
                        has = true
                    end
                end)
            end)
        end)
        return has
    end

    -- An ability by class path. False when it won't start. The game hands an enemy its moves as its AI goes along, and a
    -- guest's copy has its AI stopped, so more than half of what the host's enemy did wasn't there to replay: it's given
    -- here, once per copy and move.
    local movesLookedAt = {}      -- enemy address .. class path -> true

    -- Only an ability class goes to the ability system: any other class from a line off the wire, its default object
    -- taken for an ability inside the game, is a crash no pcall catches. Cached by class (a table field: this file is at
    -- Lua's limit of locals). By address and path: a class unloaded, another object at its address was taken for it.
    game.abilityClassSeen = {}
    function game.isAbilityClass(cls, path)
        local key = tostring(cls:GetAddress()) .. (path or "")
        if game.abilityClassSeen[key] == nil then
            local ok, yes = pcall(function()
                return cls:GetCDO():IsA(StaticFindObject("/Script/GameplayAbilities.GameplayAbility"))
            end)
            game.abilityClassSeen[key] = ok and yes == true
        end
        return game.abilityClassSeen[key]
    end

    function game.playAbility(actor, classPath)
        if not classPath:match("^/[%w_/%-]+%.[%w_%-]+$") or #classPath > 256 then
            return false
        end
        local asc = abilitySystem(actor)
        local cls = StaticFindObject(classPath)
        if not (asc and valid(cls) and game.isAbilityClass(cls, classPath)) then
            return false
        end
        local function start()
            local ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
            return ok and activated == true
        end
        if start() then
            return true
        end
        local key = actor:GetAddress() .. classPath
        if movesLookedAt[key] then
            return false
        end
        movesLookedAt[key] = true
        return not hasAbility(asc, cls) and pcall(function() asc:K2_GiveAbility(cls, 1, -1) end) and start()
    end

    function game.forgetMoves()
        movesLookedAt = {}
    end

    ------------------------------------------------------------------ hit reactions

    -- Scans every HitreactComponent, so after a miss the same actor isn't scanned again for HITREACT_RETRY_S.
    local HITREACT_RETRY_S = 2.0
    local hitreactMissUntil = {}  -- actor address -> os.clock() before which a lookup returns nil straight away
    local function hitreactComponent(actor)
        local addr = actor:GetAddress()
        if hitreactMissUntil[addr] ~= nil and os.clock() < hitreactMissUntil[addr] then
            return nil
        end
        -- (One search of every component, kept half a second, for all the lookups in that time: a search each, several
        -- copies with none came due in the same frame and hitched it.)
        local scan = game.hitScan
        if not scan or os.clock() - scan.at > 0.5 then
            scan = { at = os.clock(), byOwner = {} }
            for _, c in ipairs(FindAllOf("HitreactComponent") or {}) do
                local ok, owner = pcall(function() return c:GetOwner() end)
                if ok and valid(owner) then
                    scan.byOwner[owner:GetAddress()] = c
                end
            end
            game.hitScan = scan
        end
        local c = scan.byOwner[addr]
        if valid(c) then
            hitreactMissUntil[addr] = nil
            return c
        end
        hitreactMissUntil[addr] = os.clock() + HITREACT_RETRY_S
        return nil
    end

    -- The local player's hit state: read every frame, and whose component it is checked ten times a second (three calls).
    local hitWatch = { comp = nil, last = "None", mineAt = 0, MINE_S = 0.1 }

    -- Called every frame (coop.lua): when the local player starts reacting to a hit (stagger, knockdown...), send the
    -- hit state's tag so the other player's ghost of us reacts the same way. In the frame it starts, so the age the
    -- event gets on its way says how long ago that was: read ten times a second, it went up to 100 ms later than its age.
    function game.watchHitState(pawn, sendEvent)
        local now = os.clock()
        if now >= hitWatch.mineAt then
            hitWatch.mineAt = now + hitWatch.MINE_S
            -- (This pawn's: after a respawn the old body's stayed valid until collected, and this player's reactions stopped
            -- reaching anyone; after, another actor's at its address had theirs sent as this player's.)
            local comp = hitWatch.comp
            local mine = valid(comp) and select(2, pcall(function()
                local o = comp:GetOwner()
                return valid(o) and o:GetAddress() == pawn:GetAddress()
            end)) == true
            if not mine then
                hitWatch.comp = hitreactComponent(pawn)
            end
        end
        local comp = hitWatch.comp
        if not valid(comp) then
            return
        end
        local ok, tag = pcall(function() return comp:GetCurrentHitState().TagName:ToString() end)
        if not ok then
            return
        end
        if tag ~= hitWatch.last and tag ~= "None" then
            sendEvent("H", tag)
        end
        hitWatch.last = tag
    end

    -- This player's own hit state as last read (watchHitState, every frame): "None" when they aren't reacting to a hit.
    function game.ownHitState()
        return hitWatch.last
    end

    -- A hit state set by hand has no animation to end it, and while it lasts the character can't start a move
    -- (a PvP attacker stayed stuck after a parry). Cleared again after this long (clearHitStateLater).
    local HIT_STATE_HOLD_S = 0.9
    local clearHitStateLater      -- defined below with staggerSelf
    local ghostHitComps = {}      -- ghost address -> its component: a search of them all, so never once per hit
    -- ageS: how long ago the partner's own reaction began (net.moveAge). The copy ends when theirs does, and one that's
    -- over by now isn't played.
    function game.playHitReaction(ghost, tag, ageS)
        local holdS = HIT_STATE_HOLD_S - (ageS or 0)
        if holdS < 0.05 then
            return
        end
        local addr = ghost:GetAddress()
        local ghostHitComp = ghostHitComps[addr]
        if not valid(ghostHitComp) or ghostHitComp:GetOwner():GetAddress() ~= addr then
            ghostHitComp = hitreactComponent(ghost)
            ghostHitComps[addr] = ghostHitComp
        end
        if ghostHitComp then
            -- Already reacting (on the host, enemies here hit the ghost too): one stagger, not the same one twice.
            local okCur, cur = pcall(function() return ghostHitComp:GetCurrentHitState().TagName:ToString() end)
            if okCur and cur ~= "None" then
                return
            end
            local ok, err = pcall(function() ghostHitComp:ChangeHitState({ TagName = FName(tag) }, nil, false) end)
            if not ok then
                log("Ghost hit reaction failed: " .. tostring(err))
            else
                clearHitStateLater(ghostHitComp, tag, holdS)
            end
            holdGhost(ghost)
        end
    end

    -- Delayed actions on the game thread. One loop runs them all: a LoopInGameThreadWithDelay callback that returned
    -- true kept running in this UE4SS (the victory screen's hide timer then failed 300 times on a cleared value), so
    -- no loop here relies on stopping itself. game.after(seconds, fn) runs fn once; fn may schedule itself again.
    local timers = {}
    local schedulerStarted = false
    function game.after(seconds, fn)
        timers[#timers + 1] = { at = os.clock() + seconds, fn = fn }
        if not schedulerStarted then
            schedulerStarted = true
            LoopInGameThreadWithDelay(16, function()
                if #timers == 0 then
                    return false
                end
                local now, due, keep = os.clock(), {}, {}
                for _, t in ipairs(timers) do
                    if now >= t.at then
                        due[#due + 1] = t
                    else
                        keep[#keep + 1] = t
                    end
                end
                timers = keep
                for _, t in ipairs(due) do
                    if api.trace and api.trace.on() then
                        local info = debug.getinfo(t.fn, "S")
                        log("trace timer " .. (tostring(info and info.short_src):match("[^/" .. string.char(92) .. "]*$") or "?") .. ":" .. tostring(info and info.linedefined))
                    end
                    local ok, err = pcall(t.fn)
                    if not ok then
                        log("Timer error: " .. tostring(err))
                    end
                end
                return false
            end)
        end
    end

    -- Clear a hit state set by hand again after a moment (HIT_STATE_HOLD_S), unless something replaced it.
    clearHitStateLater = function(comp, tag, holdS)
        game.after(holdS or HIT_STATE_HOLD_S, function()
            -- (A map can load first, and a gone object's memory gets reused: pcall can't catch that crash, valid can.)
            if valid(comp) and comp:GetCurrentHitState().TagName:ToString() == tag then
                comp:ChangeHitState({ TagName = FName("None") }, nil, false)
            end
        end)
    end

    -- An enemy's hit state ("None" when it's reacting to nothing), and its component. Looked up once an enemy: a search of
    -- every component in the world.
    local enemyHitComps = {}      -- enemy address -> its HitreactComponent
    function game.hitStateOf(actor)
        local addr = actor:GetAddress()
        local comp = enemyHitComps[addr]
        if not valid(comp) or comp:GetOwner():GetAddress() ~= addr then
            comp = hitreactComponent(actor)
            enemyHitComps[addr] = comp
        end
        if not comp then
            return nil
        end
        local ok, tag = pcall(function() return comp:GetCurrentHitState().TagName:ToString() end)
        return ok and tag or nil, comp
    end

    -- The partner's hit made their copy of this enemy react, and this is the enemy itself: the same hit state, held as long as
    -- the reaction plays (set by hand, it has no animation to end it), so that its own moves keep off it meanwhile.
    function game.setHitState(actor, tag, holdS)
        local _, comp = game.hitStateOf(actor)
        if comp and pcall(function() comp:ChangeHitState({ TagName = FName(tag) }, nil, false) end) then
            clearHitStateLater(comp, tag, holdS)
            return true
        end
        return false
    end

    -- A copy's own flinch let go, so the host's move for it plays at once (puppets.lua's A, for a boss: the host says when a
    -- boss flinches, the copy's was only a guess).
    function game.clearHitState(actor)
        local state, comp = game.hitStateOf(actor)
        if comp and state and state ~= "None" then
            pcall(function() comp:ChangeHitState({ TagName = FName("None") }, nil, false) end)
        end
    end

    -- PvP: the local player reacts to a hit the game itself didn't deal (a parried swing).
    function game.staggerSelf(pawn, tag)
        local comp = hitreactComponent(pawn)
        if comp and pcall(function() comp:ChangeHitState({ TagName = FName(tag) }, nil, false) end) then
            clearHitStateLater(comp, tag)
        end
    end

    ------------------------------------------------------------------ PvP victory screen

    -- The game's own death screen (W_PlayerDead: red 殒命 calligraphy over blood, "DEAD"), turned into a golden
    -- 生还 / ALIVE for the duel's winner. Made once and only ever shown and hidden: removing this widget runs the
    -- death flow's "Refresh Monster" (enemies respawn), so it must never be removed. It ignores clicks and isn't
    -- activated, so it takes no input; its Return-to-menu button is hidden.
    local aliveScreen = nil
    local aliveScreenPainted = false
    local aliveHideAt = nil
    local GOLD = { R = 1.0, G = 0.72, B = 0.22, A = 1.0 }

    local function makeAliveScreen()
        local pc = api.getPlayer1()
        local cls = FindObject("WidgetBlueprintGeneratedClass", "W_PlayerDead_C")
        if not valid(pc) or not valid(cls) then
            return nil
        end
        local w = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
        if not valid(w) then
            return nil
        end
        w:SetVisibility(1)                                    -- collapsed until a duel is won
        w:AddToViewport(500)
        local function try(f) pcall(f) end
        try(function() w:StopAllAnimations() end)
        -- 殒命, DEAD, Return button, days counter, and the blood: the victory screen is clean gold on dark.
        for _, n in ipairs({ "yun", "ming", "Image_89", "ReturnButton", "DiedTimeBox", "Image_48", "NumText",
            "Blood1", "Blood2" }) do
            try(function() w[n]:SetVisibility(1) end)
        end
        try(function() w.red:SetRenderOpacity(0.5) end)       -- the dark backdrop stays, softer
        -- 生 over 还: a gilded ink-brush painting (art/shenghuan.png, painted in Lumina after the screen's own
        -- 殒命), shown in 殒's image slot. 命's slot stays hidden: the two slots overlap by design.
        aliveScreenPainted = false
        try(function()
            local tex = lib("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc,
                api.modRoot() .. "art/shenghuan.png")
            if valid(tex) then
                w.yun:SetBrushFromTexture(tex, false)
                local b = w.yun.Brush
                b.ImageSize = { X = 380, Y = 380 * tex:Blueprint_GetSizeY() / tex:Blueprint_GetSizeX() }
                w.yun:SetBrush(b)
                -- 殒's slot is offset upward for 殒命's layout; the two stacked characters sit centered without it.
                -- Nudged right: the brush tails sweep out to the right, so the image's middle is right of the
                -- characters' own middle; this puts the characters over ALIVE.
                w.yun:SetRenderTranslation({ X = 28, Y = 0 })
                w.yun:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 })
                w.yun:SetVisibility(3)
                aliveScreenPainted = true
            end
        end)
        if aliveScreenPainted then
            try(function() w.DeadText:SetVisibility(1) end)
        end
        -- Without the painting: 生 over 还 in the game's ink-brush font (simplified, like the screen's own 殒命;
        -- the font has no traditional 還), standing where 殒命 was.
        try(function()
            if aliveScreenPainted then
                return
            end
            local brush = nil
            for _, f in ipairs(FindAllOf("Font") or {}) do
                if f:GetFName():ToString() == "BaiGeTianXingTi_small_Font" then
                    brush = f
                end
            end
            w.DeadText:SetText(FText("生\n还"))
            w.DeadText:SetColorAndOpacity({ SpecifiedColor = GOLD, ColorUseRule = 0 })
            local f = w.DeadText.Font
            if brush then
                f.FontObject = brush
            end
            f.Size = 200
            -- Gilded brushwork: a thin dark-bronze edge around the gold strokes...
            pcall(function()
                f.OutlineSettings.OutlineSize = 3
                f.OutlineSettings.OutlineColor = { R = 0.18, G = 0.08, B = 0.02, A = 0.9 }
            end)
            w.DeadText:SetFont(f)
            -- ...and ink soaking into the paper below them.
            pcall(function()
                w.DeadText:SetShadowOffset({ X = 6, Y = 8 })
                w.DeadText:SetShadowColorAndOpacity({ R = 0.05, G = 0.0, B = 0.0, A = 0.85 })
            end)
            w.DeadText:SetAutoWrapText(false)
            w.DeadText:SetVisibility(3)
            w.DeadText:GetParent():SetVisibility(3)
        end)
        try(function()
            w.DeadRichText:SetText(FText("A L I V E"))
            w.DeadRichText:SetDefaultColorAndOpacity({ SpecifiedColor = GOLD, ColorUseRule = 0 })
        end)
        return w
    end

    -- ALIVE sits in a language switcher that shows the localized DEAD image by default: switch to the text,
    -- every time (the widget can reset it). word: what it says (a PvP match's winner: VICTORY), ALIVE by default.
    local function showAliveWord(w, word)
        pcall(function()
            local sw = w.PBZLanguageWidgetSwitcher_31
            sw:SetVisibility(3)
            sw:SetRenderOpacity(1)
            sw:SetActiveWidget(w.DeadRichText)
            w.DeadRichText:SetText(FText(word or "A L I V E"))
            w.DeadRichText:SetVisibility(3)
            w.DeadRichText:SetRenderOpacity(1)
        end)
    end

    -- The winner died (an enemy, a fall) while the victory screen showed: the death screen must not wear it.
    function game.hideAliveScreen()
        if valid(aliveScreen) and aliveHideAt then
            aliveScreen:SetVisibility(1)
            aliveHideAt = nil
        end
    end

    function game.showAliveScreen(seconds, word)
        if not valid(aliveScreen) then
            aliveScreen = makeAliveScreen()
        end
        if not valid(aliveScreen) then
            return false
        end
        showAliveWord(aliveScreen, word)
        aliveScreen:SetVisibility(3)                          -- HitTestInvisible: seen, never clicked
        -- The death screen's own entrance (Deadpopup, 5 s): the world darkens and the calligraphy appears exactly
        -- as 殒命 does. It leaves the hidden parts (DEAD, blood, 命) hidden.
        local w, t = aliveScreen, 0
        local animated = aliveScreenPainted
            and pcall(function() w:PlayAnimation(w.Deadpopup, 0, 1, 0, 1, false) end)
        if not animated then
            -- Font fallback: the strokes land, 生还 fading in from 125% to full size, then ALIVE fades in.
            pcall(function()
                w.DeadText:SetRenderOpacity(0)
                w.DeadText:SetRenderScale({ X = 1.25, Y = 1.25 })
                w.DeadRichText:SetRenderOpacity(0)
            end)
            local start = os.clock()
            local function frame()
                if not valid(w) then
                    return
                end
                t = os.clock() - start
                local a = math.min(1, t / 0.5)
                local ease = 1 - (1 - a) * (1 - a)            -- fast landing, soft settle
                local s = 1.25 - 0.25 * ease
                pcall(function()
                    w.DeadText:SetRenderOpacity(ease)
                    w.DeadText:SetRenderScale({ X = s, Y = s })
                    w.DeadRichText:SetRenderOpacity(math.max(0, math.min(1, (t - 0.4) / 0.5)))
                end)
                if t < 0.9 then
                    game.after(0.016, frame)
                end
            end
            game.after(0, frame)
        end
        -- Hidden again after `seconds`; a new win while it shows restarts the clock (only the last timer hides it).
        aliveHideAt = os.clock() + (seconds or 6)
        local mine = aliveHideAt
        game.after(seconds or 6, function()
            if aliveHideAt == mine then
                if valid(aliveScreen) then
                    aliveScreen:SetVisibility(1)
                end
                aliveHideAt = nil
            end
        end)
        return true
    end

    function game.ghostBusy(ghost)
        if api.coop and api.coop.net.party then
            return os.clock() < (busyGhosts[ghost:GetAddress()] or 0)
        end
        return os.clock() < ghostBusyUntil
    end

    -- The ghost is a full Hun: make it harmless (the remote player's hits arrive as reported damage) and let
    -- nearby enemies hate it so they fight it as well as the local player.
    -- (A token attack, not 0: at 0 its swings went through enemies with no hit at all, no sound or flash of one, and players
    -- saw the partner's blade pass through enemies. A token one lands as the game's own hit, sound and spark, for next to no
    -- damage; the real damage still comes reported. No posture: that's reported too.)
    game.GHOST_ATTACK = 0.01
    function game.setupGhost(ghost)
        pcall(function()
            local set = ghost.AttributeSetBase
            set.Attack.BaseValue = game.GHOST_ATTACK
            set.Attack.CurrentValue = game.GHOST_ATTACK
            set.ShachiAttack.BaseValue = 0
            set.ShachiAttack.CurrentValue = 0
        end)
        game.lockPointOnBody(ghost)
    end

    -- Locked onto, the camera looks at the target's lock point (an enemy's NBLockOnTargetLocation, on its body's middle).
    -- A figure is a copy of the player's class, whose only one is the player's own camera rig's (LockViewTarget), set in
    -- the world and moved by that camera alone: on a figure it stayed at the map's origin, and a lock on a foe in a match
    -- turned the camera there, not to the foe (a player's report, 11-09). On the figure's body's middle, as an enemy's.
    function game.lockPointOnBody(ghost)
        pcall(function()
            local c = ghost:GetComponentByClass(StaticFindObject("/Script/AdvancedThirdPersonCamera.ATPCLockOnTargetLocationComponent"))
            if valid(c) then
                c:SetAbsolute(false, false, false)
                c:K2_SetRelativeLocationAndRotation({ X = 0.0, Y = 0.0, Z = 0.0 }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
                    false, {}, true)
            end
        end)
    end

    -- What each player wears is theirs. The ghost is a copy of this player's class, so it came in this player's clothes
    -- (and followed this player's changes): it's dressed in what the partner says they wear (coop.lua, LOOK), through the
    -- game's own appearance component, held there as its configured look, and kept out of this player's save.
    local APPEARANCE = "/Script/ProjectPBZ.PBZAppearanceComponent"

    local function appearanceOf(actor)
        local ok, c = pcall(function() return actor:GetComponentByClass(StaticFindObject(APPEARANCE)) end)
        return ok and valid(c) and c or nil
    end

    -- This player's look: outfit, hat hidden, skin colour; or nil.
    function game.ownLook(pawn)
        local c = appearanceOf(pawn)
        if not c then
            return nil
        end
        local ok, outfit, hidden, skin = pcall(function()
            return c:GetEffectiveOutfit():ToString(), c:IsEffectiveHatHidden(), c:GetEffectiveSkinColor()
        end)
        if ok and type(outfit) == "string" and outfit:match("^[%w_]+$") and #outfit <= 64 then
            return outfit, hidden == true, math.floor(tonumber(skin) or 0)
        end
        return nil
    end

    -- True when it dressed it: false when it was so already, or it couldn't be.
    function game.dressGhost(ghost, outfit, hatHidden, skin)
        local c = appearanceOf(ghost)
        if not c then
            return false
        end
        local ok, same = pcall(function()
            return c.bUseConfiguredAppearance == true and c.CurrentOutfit:ToString() == outfit
                and c:GetEffectiveOutfit():ToString() == outfit and c:IsEffectiveHatHidden() == hatHidden
                and c:GetEffectiveSkinColor() == skin
        end)
        if ok and same then
            return false
        end
        return (pcall(function()
            c:BeginSuppressAppearanceSave()
            -- The face goes by this one: left as this player's (the ghost began as a copy of them), a ghost made anew in
            -- an outfit with a face of its own had this player's plain face on it.
            c.CurrentOutfit = FName(outfit)
            c:SetConfiguredAppearance(FName(outfit), hatHidden, skin)
            c:SetUseConfiguredAppearance(true)
            c:ApplyOutfitVisual(FName(outfit), not hatHidden, skin, true)
            pcall(function() c:RefreshHealthMaterial(1.0) end)
        end))
    end

    -- Enemies here can't touch the ghost: the partner takes their hits on their own PC, and the ghost is told what
    -- happened there. Without this a replayed attack landed on it too and knocked it metres off, on this PC alone.
    local ghostShield, shieldedGhost = nil, nil
    function game.ghostGone()
        ghostShield, shieldedGhost = nil, nil
    end

    function game.shieldGhost(ghost, on)
        pcall(function()
            local asc = abilitySystem(ghost)
            if shieldedGhost ~= ghost:GetAddress() then
                shieldedGhost, ghostShield = ghost:GetAddress(), nil    -- a new ghost (a map change): nothing on it yet
            end
            if on and not ghostShield then
                local cls = FindObject("BlueprintGeneratedClass", "GE_PBZLieInvulnerable_C")
                ghostShield = asc:BP_ApplyGameplayEffectToSelf(cls, 1, asc:MakeEffectContext())
            elseif not on and ghostShield then
                asc:RemoveActiveGameplayEffect(ghostShield, -1)
                ghostShield = nil
            end
        end)
    end

    -- Every second (host): the ghost stays at full health, since the remote player's real health lives on their PC.
    -- (In PvP the ghost's health shows the remote player's real health instead: pvp.lua sets it.)
    function game.healGhost(ghost, pvp)
        local _, maxhp = game.getHealth(ghost)
        if maxhp and not pvp then
            game.setHealth(ghost, maxhp)
        end
    end

    -- An enemy close to the ghost adds it to its hatred list, so it fights the ghost as well as the local player.
    -- Walking its hatred list takes about ten calls, so one that has the ghost on it isn't asked again for a while.
    local HATE_RECHECK_S = 5.0
    local hatesGhost = {}         -- enemy address -> os.clock() of the next look
    -- who: which ghost, with more than one, and at: where it is, known without asking the game.
    function game.hateGhost(e, ghost, addr, x, y, z, who, at)
        local now = os.clock()
        local key = who and (who .. ":" .. addr) or addr
        if now < (hatesGhost[key] or 0) then
            return
        end
        local g = at or ghost:K2_GetActorLocation()
        if not (x and distance({ X = x, Y = y, Z = z }, g) <= GHOST_AGGRO_CM) then
            return
        end
        hatesGhost[key] = now + HATE_RECHECK_S
        pcall(function()
            local hm = e.BP_PBZHatredManagerComponent
            local already = false
            hm.HatredList:ForEach(function(_, a)
                local actor = a:get()
                if valid(actor) and actor:GetAddress() == ghost:GetAddress() then
                    already = true
                end
            end)
            if not already then
                hm:AddActorToHatredList(ghost, {})
            end
        end)
    end

    ------------------------------------------------------------------ who an enemy goes for

    -- An enemy's own script picks its target: the nearest on its hatred list, looked at again each time it's hit or starts a
    -- move, 1.5 s after the last change. With two players near it that flips all the time: a boss turned back and forth as
    -- it walked. Holding one player for 15 s and then turning to whoever hit it last turned it by the clock, "worse than
    -- deciding by distance and by who deals the most damage" (a player's report). So an enemy near two players or more goes
    -- for whoever scores most, the same with 2, 4 or 6:
    --   near     1 within CLOSE_CM, 0 at REACH_CM, in a line between
    --   damage   the health they took from it lately (halving every HALF_S): 1 for whoever took most, the others in
    --            proportion, and less for everyone while nobody has taken FIRST_HITS of the biggest hit on it lately (so a
    --            first hit isn't "the most damage", whatever its health: a floor of 3% of it meant 10000 on a boss of 333180,
    --            and in the real game a guest hitting it for a minute was never noticed)
    --   healing  HEAL_W while they drink from the gourd, for HEAL_S from the start: a drink draws its eye (the owner's
    --            word), within the same hold and wait as any turn
    -- It turns only to someone MARGIN ahead of whoever it's after, once it has held them HOLD_S (a boss BOSS_HOLD_S), and not
    -- in the middle of one of its moves (it waits up to MOVE_WAIT_S for one to end). Someone who goes past REACH_CM isn't held
    -- to. Its own picker is held off meanwhile, its wait GAME_HOLD_S and its last change put at now each turn: left to look
    -- by itself, it turned to the nearest behind the score's back and was turned back, the same back and forth. The script
    -- does the turning, with the others off its list for that moment.
    local aim = {
        REACH_CM = GHOST_AGGRO_CM,  -- farther off than this a player isn't in this fight
        CLOSE_CM = 300,
        HALF_S = 12.0,
        FIRST_HITS = 2.5,
        HEAL_W = 1.0,               -- as much as having done the most damage
        HEAL_S = 4.0,               -- a turn's look each second, and a move's end waited for up to 2 s, fit in it
        MARGIN = 0.5,
        HOLD_S = 6.0,
        BOSS_HOLD_S = 10.0,
        MOVE_WAIT_S = 2.0,
        GAME_HOLD_S = 15.0,         -- (not longer: with a day's wait a real boss turned to a guest, then no attack in a minute)
        GAME_WAIT_S = 1.5,          -- its picker's own wait, given back when the one it had was already ours
        OWN_HIT_S = 2.0,            -- health it lost is this player's hit if they started a move this recently
        LOOK_S = 2.5,               -- and the look before was this recent (over a longer gap it says nothing of who)
        steered = {},               -- enemy address -> { picker, actor, fname, orig, slot, since, wantSince }
        dmg = {},                   -- enemy address -> { at, hp, seen, taken, big, [slot] = health taken lately }
        healAt = {},                -- slot -> os.clock() of that player's last drink
    }
    game.aim = aim                  -- (for tests, and a look from the console)

    local function targetPicker(actor)
        local found = nil
        pcall(function()
            actor.Controller.SGameAIComponent.SpawnedAIScripts:ForEach(function(_, element)
                pcall(function()
                    local script = element:get()
                    if found == nil and valid(script) and script:GetClass():GetFName():ToString() == "AIScript_TargetSelector_C" then
                        found = script
                    end
                end)
            end)
        end)
        return found
    end

    local function currentTarget(actor)
        local out = {}
        local ok = pcall(function()
            StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary"):GetTargetActor(actor.Controller, out)
        end)
        return ok and valid(out.Target) and out.Target or nil
    end

    -- Host: who this enemy is after, as "host", "guest" or "-".
    function game.enemyAfter(actor, ghost)
        local target = currentTarget(actor)
        if target == nil then
            return "-"
        end
        return valid(ghost) and target:GetAddress() == ghost:GetAddress() and "guest" or "host"
    end

    -- The same with more than two players: the slot of who it's after, or "-". ghosts: ghost address -> slot.
    function game.enemyAfterSlot(actor, ghosts)
        local target = currentTarget(actor)
        if target == nil then
            return "-"
        end
        return ghosts[target:GetAddress()] or 1
    end

    -- Guest: a move lunges at its enemy's target, so a copy with none fell short of the host's and was dragged the rest of the
    -- way, attack pose and all. It's given the host's target, and its own picker is told to leave that alone.
    local copyPickers = {}        -- enemy address -> its target picker
    local copyCooldowns = {}      -- enemy address -> how long its picker waited before it was told to leave a target alone
    local TARGET_KEY = "AI.BlackboardKey.Object.TargetActor"
    local LONG_S = 86400.0
    function game.aimCopy(actor, addr, target)
        pcall(function()
            local picker = copyPickers[addr]
            if not valid(picker) then
                picker = targetPicker(actor)
                copyPickers[addr] = picker
            end
            if picker then
                -- (Not the held-off value itself: read again after a forget, it was restored as the original, and the
                -- enemy never changed targets on its own again.)
                if not copyCooldowns[addr] and (picker.SwitchTargetCooldown or LONG_S) < LONG_S then
                    copyCooldowns[addr] = picker.SwitchTargetCooldown
                end
                picker.SwitchTargetCooldown = LONG_S
                picker.LastSwitchTime = api.gs():GetTimeSeconds(actor)
            end
            StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary"):SetValueAsObjectByTag(actor.Controller.Blackboard,
                { TagName = FName(TARGET_KEY) }, target)
        end)
    end

    -- A copy let go is its own again: the target it was given may be a ghost that's gone, so it looks for one now, not in a day.
    -- forgetOnly: the copy is dead or gone, and its picker may be too (its address someone else's): only forgotten.
    function game.freeCopy(addr, forgetOnly)
        local picker, cooldown = copyPickers[addr], copyCooldowns[addr]
        copyPickers[addr], copyCooldowns[addr] = nil, nil
        if cooldown and valid(picker) and not forgetOnly then
            pcall(function()
                picker.SwitchTargetCooldown = cooldown
                picker.LastSwitchTime = 0
                picker:TrySwitchTarget()
            end)
        end
    end

    -- The health each player took from this enemy lately, as of now: what was there halves every HALF_S.
    function aim.lately(addr, now)
        local d = aim.dmg[addr]
        if d == nil then
            d = { at = now, taken = 0 }
            aim.dmg[addr] = d
        end
        local keep = 0.5 ^ ((now - d.at) / aim.HALF_S)
        for slot, v in pairs(d) do
            if type(slot) == "number" then
                d[slot] = v * keep
            end
        end
        d.big = (d.big or 0) * keep     -- the biggest single hit lately
        d.at = now
        return d
    end

    -- Host: a partner's hit landed here (their D). slot: theirs, 2 with two players. taken: the health it took.
    function game.partnerHit(addr, slot, taken)
        local d = aim.lately(addr, os.clock())
        taken = math.max(0, tonumber(taken) or 0)
        slot = slot or 2
        d[slot] = (d[slot] or 0) + taken
        d.big = math.max(d.big, taken)
        d.taken = d.taken + taken       -- (what this player's turn sees it lost isn't theirs for that much)
    end

    -- Host: a player started a drink from the gourd (theirs by HEAL, this player's own by watchItemFx). slot: 1 for the host.
    function game.playerHealed(slot)
        aim.healAt[slot or 2] = os.clock()
    end

    -- An enemy no longer steered: its picker's own wait back, if it's still that enemy (address and name). It looks again at
    -- its next chance, as it would have.
    function aim.release(addr)
        local f = aim.steered[addr]
        aim.steered[addr] = nil
        if f then
            pcall(function()
                if valid(f.actor) and f.actor:GetAddress() == addr and f.actor:GetFName():ToString() == f.fname
                    and valid(f.picker) then
                    f.picker.SwitchTargetCooldown = f.orig
                end
            end)
        end
    end

    -- (Each steered enemy's own wait back: kept at ours, every enemy ever steered took 15 s to change targets for the rest of
    -- the session.)
    function game.forgetFocus()
        for addr in pairs(aim.steered) do
            aim.release(addr)
        end
        aim.steered, aim.dmg, aim.healAt = {}, {}, {}
    end

    -- One enemy done with (dead, or nobody near it): its wait back, its damage forgotten.
    function game.unfocus(addr)
        aim.release(addr)
        aim.dmg[addr] = nil
    end

    -- The entry for an enemy steered now (the one kept if it's still this enemy's, by address and name), its own picker held
    -- off.
    function aim.hold(actor, addr, on, now)
        local f = aim.steered[addr]
        local fname = nil
        pcall(function() fname = actor:GetFName():ToString() end)
        if not (f and valid(f.picker) and f.fname == fname) then
            f = { picker = targetPicker(actor), actor = actor, fname = fname, orig = aim.GAME_WAIT_S, slot = on and on.slot,
                since = now }
            if f.picker == nil then
                return nil
            end
            aim.steered[addr] = f
            pcall(function()
                local wait = f.picker.SwitchTargetCooldown
                -- (Not a wait that was already ours: given back as its own, it never turned by itself again.)
                if wait and wait < aim.GAME_HOLD_S then
                    f.orig = wait
                end
                f.picker.SwitchTargetCooldown = aim.GAME_HOLD_S
            end)
        end
        pcall(function() f.picker.LastSwitchTime = api.gs():GetTimeSeconds(actor) end)
        return f
    end

    -- Who of those near scores most, and by how much over `on` (nil: over nobody). A tie stays with `on`.
    function aim.best(d, near, on)
        local top = aim.FIRST_HITS * (d.big or 0)
        for _, who in ipairs(near) do
            top = math.max(top, d[who.slot] or 0)
        end
        top = math.max(top, 1)
        local now = os.clock()
        for _, who in ipairs(near) do
            who.score = math.max(0, math.min(1, (aim.REACH_CM - who.dist) / (aim.REACH_CM - aim.CLOSE_CM)))
                + (d[who.slot] or 0) / top
                + (now - (aim.healAt[who.slot] or -1e9) < aim.HEAL_S and aim.HEAL_W or 0)
        end
        local best = on or near[1]
        for _, who in ipairs(near) do
            if who.score > best.score then
                best = who
            end
        end
        return best, best.score - (on and on.score or 0)
    end

    -- Turns an enemy to one player, the game's own way: the others near off its list for that moment, its picker asked now.
    -- A turn that didn't take (its hatred refused the body, or its picker kept the old target): no new hold, which made a boss
    -- stay on the host a whole hold for each refusal ("the aggro is completely on the host", 1.6.6), asked again after
    -- MOVE_WAIT_S. Said once an enemy, for the bench and the reports.
    function aim.refused(f, actor, best, now)
        f.retryAt = now + aim.MOVE_WAIT_S
        f.refusals = (f.refusals or 0) + 1
        if f.refusals == 1 then
            log("Aggro: " .. tostring(className(actor)) .. " wouldn't turn to player " .. tostring(best.slot)
                .. ": asked again in a moment.")
        end
    end

    function aim.turn(actor, f, best, near)
        local now = os.clock()
        local hatred = actor.BP_PBZHatredManagerComponent
        if not valid(hatred) or hatred:CheckCanHatredTarget(best.body) == false then
            aim.refused(f, actor, best, now)
            return
        end
        pcall(function()
            hatred:AddActorToHatredList(best.body, {})
            for _, who in ipairs(near) do
                if who ~= best then
                    hatred:RemoveActorFromHatredList(who.body)
                end
            end
            f.picker.LastSwitchTime = 0
            f.picker:TrySwitchTarget()
        end)
        for _, who in ipairs(near) do      -- (whatever happened above, the others go back on its list)
            if who ~= best then
                pcall(function() hatred:AddActorToHatredList(who.body, {}) end)
            end
        end
        -- (Whether it took: its target now. A turn its picker didn't make isn't one: taken for one, the next look read the
        -- old target as "turned by itself" and held it a whole hold again. If its target only shows the turn a tick on, the
        -- next look sees it turned and holds the new one.)
        local t = currentTarget(actor)
        if t and t:GetAddress() == best.addr then
            f.slot, f.since, f.wantSince, f.retryAt = best.slot, now, nil, nil
        else
            aim.refused(f, actor, best, now)
        end
    end

    -- Host, an enemy's aggro turn, with any number of players. players: { body, addr, at, slot, mine } for each one up and
    -- here (mine: this PC's own player, whose hits show only as health it lost). boss: it holds longer. busy: it's in one of
    -- its moves now.
    function game.steerTarget(actor, addr, x, y, z, hp, players, boss, busy)
        if not x then
            return
        end
        local now, at, near = os.clock(), { X = x, Y = y, Z = z }, {}
        for _, who in ipairs(players) do
            who.dist = distance(at, who.at)
            if who.dist <= aim.REACH_CM then
                near[#near + 1] = who
            end
        end
        if #near == 0 then
            game.unfocus(addr)
            return
        end
        local d = aim.lately(addr, now)
        -- What it lost since the last look, less what partners' hits took, is this player's if they swung lately.
        if hp and d.hp and d.seen and now - d.seen <= aim.LOOK_S and game.localMoveRecent(aim.OWN_HIT_S) then
            local own = d.hp - hp - d.taken
            for _, who in ipairs(near) do
                if who.mine and own > 0.5 then
                    d[who.slot] = (d[who.slot] or 0) + own
                    d.big = math.max(d.big, own)
                end
            end
        end
        d.hp, d.seen, d.taken = hp, now, 0
        if #near < 2 then
            aim.release(addr)
            return
        end
        local target = currentTarget(actor)
        local targetAddr = target and target:GetAddress()
        local on, player = nil, false
        for _, who in ipairs(players) do
            if targetAddr and who.addr == targetAddr then
                on, player = who.dist <= aim.REACH_CM and who or nil, true
            end
        end
        if not player then
            aim.release(addr)       -- (after nobody, or after something that isn't a player here: not ours to steer)
            return
        end
        local f = aim.hold(actor, addr, on, now)
        if f == nil then
            return
        end
        local best, lead = aim.best(d, near, on)
        if on == nil then
            -- Who it was after has gone past REACH_CM: not held to. (Tried again only after MOVE_WAIT_S: a turn its picker
            -- won't make, with something else nearer on its list, isn't asked for every second.)
            if now - (f.forcedAt or -1e9) >= aim.MOVE_WAIT_S then
                f.forcedAt = now
                aim.turn(actor, f, best, near)
            end
            return
        end
        if f.slot ~= on.slot then
            f.slot, f.since, f.wantSince = on.slot, now, nil    -- (it turned by itself: its target out of its sight)
        end
        if best == on or lead < aim.MARGIN or now - f.since < (boss and aim.BOSS_HOLD_S or aim.HOLD_S) then
            f.wantSince = nil
            return
        end
        f.wantSince = f.wantSince or now
        if (busy and now - f.wantSince < aim.MOVE_WAIT_S) or now < (f.retryAt or 0) then
            return
        end
        aim.turn(actor, f, best, near)
    end

    -- A hidden ghost is nobody to fight: the partner's down, gone or elsewhere, and enemies swung at thin air. It comes off
    -- every list, can't be put back, and each enemy that was after it looks again. With nobody else on its list that look finds
    -- no one and it keeps its target for good, swinging at the empty spot, so this player goes on the list first.
    function game.ghostInFight(ghost, inFight, enemies)
        pcall(function() ghost.BP_PBZHatredManagerComponent.CanBeHatredNow = inFight end)
        if inFight then
            return
        end
        hatesGhost = {}
        local _, pawn = api.getPlayer1()
        local alive = valid(pawn) and not game.isDead(pawn)
        for _, actor in pairs(enemies) do
            if valid(actor) and not game.isDead(actor) then
                pcall(function()
                    local hatred = actor.BP_PBZHatredManagerComponent
                    hatred:RemoveActorFromHatredList(ghost)
                    local target = currentTarget(actor)
                    if target and target:GetAddress() == ghost:GetAddress() then
                        if alive then
                            hatred:AddActorToHatredList(pawn, {})
                        end
                        local picker = targetPicker(actor)
                        picker.LastSwitchTime = 0
                        picker:TrySwitchTarget()
                    end
                end)
            end
        end
    end

    ------------------------------------------------------------------ bells and refreshes

    -- The player's respawn after death runs a "Respawn Refresh Monster" step, which calls the game mode's "Refresh Monster".
    -- What that brings back is up to each spawner: a boss from its spawner yes, a camp of thugs no. (In this game the dead
    -- mostly stay dead, at a bell too.) When it runs on one PC, the other PC runs its own, so both worlds do the same. The
    -- hook is registered once gameplay is up (the blueprint must be loaded first). The respawn step is hooked too, so onRest
    -- gets "death", or "bell" for a refresh with no death: nothing in the game does that, only a mod that adds respawns.
    local REFRESH_FN = "/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster"
    local RESPAWN_REFRESH_FN = "/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:Respawn Refresh Monster"
    local RESPAWN_WINDOW_S = 3.0
    local restHooked, refreshing = false, false
    local respawnRefreshAt = nil

    function game.hookRest(onRest)
        if restHooked or not valid(StaticFindObject(REFRESH_FN)) then
            return restHooked
        end
        if valid(StaticFindObject(RESPAWN_REFRESH_FN)) then
            local okR, errR = pcall(function()
                RegisterHook(RESPAWN_REFRESH_FN, function()
                    respawnRefreshAt = os.clock()
                end)
            end)
            if not okR then
                log("Respawn hook failed (deaths will count as bell rests): " .. tostring(errR))
            end
        end
        local ok, err = pcall(function()
            RegisterHook(REFRESH_FN, function()
                if refreshing then
                    return
                end
                -- Blueprint hooks run after their function, so the respawn step's hook (the caller) only runs
                -- once Refresh Monster (the callee) is done: decide a moment later, when both have reported.
                local at = os.clock()
                game.after(0.5, function()
                    local death = respawnRefreshAt ~= nil and math.abs(respawnRefreshAt - at) <= RESPAWN_WINDOW_S
                    respawnRefreshAt = nil
                    onRest(death and "death" or "bell")
                end)
            end)
        end)
        restHooked = ok
        log(ok and "Bell/respawn hook ready." or ("Bell hook failed: " .. tostring(err)))
        return restHooked
    end

    -- The other player's world refreshed: this one does too.
    function game.refreshEnemies()
        local pc = api.getPlayer1()
        local gm = valid(pc) and api.gs():GetGameMode(pc) or nil
        if not valid(gm) then
            return false
        end
        refreshing = true
        local ok, err = pcall(function() gm["Refresh Monster"](gm) end)
        refreshing = false
        if not ok then
            log("Refresh Monster failed: " .. tostring(err))
        end
        return ok
    end

    -- respawnrefresh: test helper, run the respawn's own monster refresh step as if player 1 had died and respawned
    -- (only that step: no save, no days lost, no teleport).
    game.commands.respawnrefresh = function()
        local _, pawn = api.getPlayer1()
        local ok, err = pcall(function() pawn["Respawn Refresh Monster"](pawn) end)
        log("Respawn Refresh Monster: " .. tostring(ok) .. " " .. tostring(err))
    end

    function game.backpackOf(pawn)
        local ok, bp = pcall(function()
            return StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(pawn,
                StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem"))
        end)
        return ok and valid(bp) and bp or nil
    end

    function game.gourdInfo(pawn)
        local bp = game.backpackOf(pawn)
        local found = nil
        pcall(function()
            local id = bp.BottomMedicineID:ToString()
            bp.MedicineInfos:ForEach(function(k, v)
                if k:get():ToString() == id then
                    found = v:get()
                end
            end)
        end)
        return found
    end

    -- gourd: a player who came out of a new game's prologue with no healing gourd to drink from gets it back, equipped and full.
    -- (Players of 1.6.3 lost it in co-op: see game.inPrologue.) Says what it found.
    -- quiet: no pickup card (the catch-up on joining, see game.mergeBag).
    function game.giveGourd(quiet)
            local _, pawn = api.getPlayer1()
            local bp = valid(pawn) and game.backpackOf(pawn)
            if not bp then
                log("Gourd: no player or bag yet.")
                return
            end
            local bottom, has = "?", false
            pcall(function() bottom = bp.BottomMedicineID:ToString() end)
            pcall(function()
                bp.MedicineInfos:ForEach(function(k)
                    if k:get():ToString() == "Hulu" then
                        has = true
                    end
                end)
            end)
            if has and bottom == "Hulu" then
                log("Gourd: equipped already.")
            else
                local ok = pcall(function() bp:PushMedicineToInventory(FName("Hulu"), true, not quiet) end)
                pcall(function() bottom = bp.BottomMedicineID:ToString() end)
                log("Gourd: given back " .. (ok and "" or "(the game wouldn't) ") .. "and equipped as " .. tostring(bottom) .. ".")
            end
            local g = game.gourdInfo(pawn)
            if g then
                pcall(function()
                    g:SetCurrentTime(g.MaxTime)
                    g:SetDisplayTime(g.MaxTime)
                end)
            end
    end
    if game.commands then
        game.commands.gourd = function()
            game.giveGourd()
        end
    end

    -- (No prologue skip of our own any more: the bag's RestoreEquipmentAfterPrologue gave the gear back, but the player
    -- stayed in the prologue's young body. The game's own skip at New Game is the one: see prologue.lua.)

    -- Sitting at a bell heals, fills the gourd and saves, and runs no Refresh Monster. RestoreHealth is the step every sit has,
    -- the first ring included. It works on player 1 from any bell, however far: a partner's sit rests this player with it.
    local SIT_FN = "/Script/ProjectPBZ.MelodiousBell:RestoreHealth"
    local sitHooked, restingHere = false, false

    function game.hookSit(onSit)
        if sitHooked or not valid(StaticFindObject(SIT_FN)) then
            return sitHooked
        end
        local ok, err = pcall(function()
            RegisterHook(SIT_FN, function()
                if not restingHere then
                    game.after(0, onSit)
                end
            end)
        end)
        sitHooked = ok
        log(ok and "Bell sit hook ready." or ("Bell sit hook failed: " .. tostring(err)))
        return sitHooked
    end

    -- A bell's first ring, its first touch: a crane bell's scene follows it about 5 s on (bench, 11-12), story.lua's to
    -- know as this player's own. Hooked once the bell's blueprint is loaded (it comes with the level's bells): true then.
    -- (Fields, not locals: this function is at the 200 locals Lua allows.)
    game.firstTouch = { FN = "/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C:OnFirstTouchBell" }
    function game.hookFirstTouch()
        local ft = game.firstTouch
        if ft.hooked or not valid(StaticFindObject(ft.FN)) then
            return ft.hooked == true
        end
        ft.hooked = pcall(function()
            RegisterHook(ft.FN, function()
                game.firstTouchAt = os.clock()
            end)
        end)
        return ft.hooked
    end

    -- Rest this player as a sit would. Health through the bell's own step: written by hand it leaves the low health look on
    -- the screen. The gourd by hand: the bell's "Restore BackPack Data" also saves, with that bell as the place to respawn.
    function game.restHere(pawn)
        local bell = FindFirstOf("MelodiousBell")
        local healed = false
        if valid(bell) then
            restingHere = true
            healed = pcall(function() bell:RestoreHealth() end)
            restingHere = false
        end
        if not healed then
            local _, maxhp = game.getHealth(pawn)
            if maxhp then
                game.setHealth(pawn, maxhp)
            end
        end
        local gourd = game.gourdInfo(pawn)
        if gourd then
            pcall(function()
                local max = gourd.MaxTime
                if type(max) == "number" then
                    gourd:SetCurrentTime(max)
                    gourd:SetDisplayTime(max)
                end
            end)
        end
    end

    -- This player's own health bar, told by hand what the health is now and shown a moment, as for a real change (the HUD's
    -- own ForSeq_UpdatePlayerHP, as local co-op tells player 2's). Health written by hand reaches no listener: the bar follows
    -- only the game's own changes. (The HUD found each time, never kept across frames.)
    function game.showPlayerHealth(pawn)
        local hp, maxhp = nil, nil
        if valid(pawn) then
            hp, maxhp = game.getHealth(pawn)
        end
        local hud = hp and maxhp and maxhp > 0 and FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            return false            -- (no HUD, mid-load: a call on nothing is a crash in UE4SS, not an error)
        end
        local ok = pcall(function() hud:ForSeq_UpdatePlayerHP(math.min(1.0, math.max(0.0, hp / maxhp))) end)
        pcall(function() hud["Need To Show"](hud) end)
        return ok
    end

    -- This player's health to hp, shown as the game shows a change of its own. Written by hand (setHealth) it reaches neither
    -- the player's bar nor the game's low health look: on the bench (11-07) a duel's player refilled for the next round stood
    -- at full health with an empty bar and the near-death look on till the next blow (issue #13 had warned of the bar). So
    -- it's filled the game's way first, which tells both: the game's own recovery effects (REFILL_EFFECTS, health alone
    -- first; one that would stay on is taken off at once, so nothing heals on after), else a loaded bell's own step, as
    -- restHere (no sit hook hears it: in a match a sit is a forfeit). Then hp written, if that didn't reach it or a lower one
    -- is wanted (home: the health from before the match; the look stays off), and the bar told where the game didn't.
    -- game.refillHow says which way it went: full (nothing to fill), an effect's name, bell, or hand.
    game.REFILL_EFFECTS = {
        "/Game/PBZContent/DataTable/Character/GameplayEffects/GE_RevocerHealth",
        "/Game/PBZContent/DataTable/Character/GameplayEffects/GE_RevocerHealthAndAnger",
    }
    function game.refillPlayer(pawn, hp)
        local maxhp = valid(pawn) and select(2, game.getHealth(pawn)) or nil
        if not (maxhp and maxhp > 0) then
            return
        end
        local function filled()
            local now = game.getHealth(pawn)
            return now ~= nil and now >= maxhp - 0.5
        end
        local how = filled() and "full" or nil
        local a = nil
        if not how then
            pcall(function()
                a = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
                    :GetAbilitySystemComponent(pawn)
            end)
        end
        for _, path in ipairs((not how and valid(a)) and game.REFILL_EFFECTS or {}) do
            local short = path:match("([^/]+)$")
            -- (Only one already in memory: they're the game's own and normally are. Never loaded here: round 1's refill
            -- comes right after the arena's trip, the moment a load once took UE4SS down (arena.lua's preload); the bell's
            -- step or the bar told by hand covers one that isn't. The review of 1.7.0.)
            local cls = StaticFindObject(path .. "." .. short .. "_C")
            if valid(cls) then
                pcall(function()
                    local handle = a:BP_ApplyGameplayEffectToSelf(cls, 1, a:MakeEffectContext())
                    if handle then
                        a:RemoveActiveGameplayEffect(handle, -1)
                    end
                end)
            end
            if filled() then
                how = short
                break
            end
        end
        if not how then
            local bell = FindFirstOf("MelodiousBell")
            if valid(bell) then
                restingHere = true
                pcall(function() bell:RestoreHealth() end)
                restingHere = false
                how = filled() and "bell" or nil
            end
        end
        local want = math.max(1, math.min(hp or maxhp, maxhp))
        game.setHealth(pawn, want)
        if how == nil or how == "full" or want < maxhp - 0.5 then
            game.showPlayerHealth(pawn)
        end
        if how == nil and not game.refillSaid then
            game.refillSaid = true
            log("Health refilled by hand: neither the game's recovery effects nor a bell's step filled it. The bar is told, " ..
                "the low health look may stay till the next change.")
        end
        game.refillHow = how or "hand"
    end

    ------------------------------------------------------------------ spectating

    -- While the local player is dead, the camera can follow the other player's ghost. The game's death screen is
    -- dimmed, not removed or hidden (it drives the respawn: removing it runs Refresh Monster, and a hidden widget
    -- may stop ticking), and comes back the moment we stop.
    -- The view comes from a camera of our own placed behind and above the partner every frame, looking at them:
    -- the ghost's own camera can't be used (it follows a controller the ghost doesn't have, so it sat in the
    -- bamboo looking nowhere).
    local spectating = nil        -- the actor the camera follows, or nil
    -- The address of what the camera follows (a ghost about to be put away), or nil.
    function game.spectatingAt()
        return spectating and valid(spectating) and spectating:GetAddress() or nil
    end
    local spectateCam = nil
    local DEATH_SCREEN_DIM = 0.25
    local CAM_BACK_CM, CAM_UP_CM, CAM_FOLLOW = 380, 170, 0.12   -- behind, above, fraction of the way per frame

    local function deathScreen(pawn)
        local ok, w = pcall(function() return pawn["Death Widget"] end)
        return (ok and valid(w)) and w or nil
    end

    -- The death screen's tick is what leads to the respawn: stopped, the player waits, and it goes on from there. (The
    -- screen is found on the player each time and known by its address: a widget kept from an earlier frame can read as
    -- valid after it's gone, and a write to it crashed.)
    local heldScreenAt = nil
    function game.holdRespawn(pawn, on)
        if on then
            local w = valid(pawn) and deathScreen(pawn)
            if w then
                if w.NotTick ~= true then
                    w.NotTick = true
                end
                heldScreenAt = w:GetAddress()
            end
            return heldScreenAt ~= nil
        end
        if heldScreenAt ~= nil then
            if not valid(pawn) then
                pawn = select(2, api.getPlayer1())
            end
            local w = valid(pawn) and deathScreen(pawn)
            if w and w:GetAddress() == heldScreenAt then
                pcall(function() w.NotTick = false end)
            end
        end
        heldScreenAt = nil
        return false
    end

    local function camSpot(target)
        local l = target:K2_GetActorLocation()
        local yaw = math.rad(target:K2_GetActorRotation().Yaw)
        return { X = l.X - math.cos(yaw) * CAM_BACK_CM, Y = l.Y - math.sin(yaw) * CAM_BACK_CM, Z = l.Z + CAM_UP_CM }, l
    end

    local function aim(from, at)
        local dx, dy, dz = at.X - from.X, at.Y - from.Y, (at.Z + 60) - from.Z
        return { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0.0 }
    end

    -- One step, every frame while it follows: coop's frameTicks.cameras, called with nothing. (On game.after's 16 ms loop it
    -- moved every second or third frame at a high frame rate, a judder; the review of 1.7.0.) loop: the timer's way, only
    -- with no coop ticks to run on.
    local function followFrame(loop)
        if not (spectating and valid(spectating) and valid(spectateCam)) then
            game.spectateTick = nil
            return
        end
        local want, at = camSpot(spectating)
        local cur = spectateCam:K2_GetActorLocation()
        local a = CAM_FOLLOW
        local pos = { X = cur.X + (want.X - cur.X) * a, Y = cur.Y + (want.Y - cur.Y) * a, Z = cur.Z + (want.Z - cur.Z) * a }
        spectateCam:K2_SetActorLocationAndRotation(pos, aim(pos, at), false, {}, true)
        if loop then
            game.after(0.016, function() followFrame(true) end)
        end
    end

    function game.spectate(target)
        local pc, pawn = api.getPlayer1()
        if not valid(pc) or not valid(pawn) then
            return false
        end
        local follow = valid(target) and target or nil
        if spectating and not valid(spectating) then
            spectating = nil        -- (gone, a ghost destroyed as the party shrank: never asked anything again)
        end
        if (follow and spectating and follow:GetAddress() == spectating:GetAddress()) or (not follow and not spectating) then
            return true
        end
        local ok = true
        if follow then
            if not valid(spectateCam) then
                local spot, at = camSpot(follow)
                local gs = api.gs()
                local t = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = spot, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
                ok = pcall(function()
                    local cam = gs:BeginDeferredActorSpawnFromClass(pc, StaticFindObject("/Script/Engine.CameraActor"), t,
                        SPAWN_ADJUST_ALWAYS, nil, SCALE_MULTIPLY_WITH_ROOT)
                    spectateCam = gs:FinishSpawningActor(cam, t, SCALE_MULTIPLY_WITH_ROOT)
                    spectateCam:K2_SetActorLocationAndRotation(spot, aim(spot, at), false, {}, true)
                end) and valid(spectateCam)
            end
            ok = ok and pcall(function() pc:SetViewTargetWithBlend(spectateCam, 1.0, 0, 0, false) end)
        else
            ok = pcall(function() pc:SetViewTargetWithBlend(pawn, 0.4, 0, 0, false) end)
            if valid(spectateCam) then
                local cam = spectateCam
                game.after(0.5, function() if valid(cam) and cam ~= spectateCam then cam:K2_DestroyActor() end end)
            end
            spectateCam = nil
        end
        local w = deathScreen(pawn)
        if w then
            pcall(function() w:SetRenderOpacity(follow and ok and DEATH_SCREEN_DIM or 1.0) end)
        end
        local wasFollowing = spectating ~= nil
        spectating = (ok and follow) or nil
        if spectating and not wasFollowing then
            -- (Run by coop's frameTicks.cameras, a key made once at its load: one made here, from inside that loop, was a new
            -- key in the middle of its traversal, which Lua leaves undefined.)
            if api.coop and api.coop.frameTicks then
                game.spectateTick = followFrame
            else
                game.after(0.016, function() followFrame(true) end)
            end
        end
        return ok
    end

    function game.isSpectating()
        return spectating ~= nil
    end

    -- A PvP finishing move's camera (arena.lua), as a fighting game shows one: beside the two bodies and low, turning round
    -- them from the winner's face to the beaten's and closing in while the move plays, a narrower lens than the game's.
    -- bodies(): the two, asked again each frame (none kept). Real seconds, so it keeps moving through the slowed blow.
    -- Then the view goes back: to the spectating camera if that was on, else this player.
    do      -- (a block of its own: this function is at the 200 locals Lua allows)
    local cinemaCam, cinemaRun = nil, 0
    local CINE_FROM_DEG, CINE_TO_DEG = 58, 108          -- round the pair, from the line winner -> beaten
    local CINE_FAR_CM, CINE_NEAR_CM = 560, 380
    local CINE_HIGH_CM, CINE_LOW_CM = 110, 30           -- above the bodies' middles
    local CINE_FOV = 55
    -- Kept clear of rock and wall as the game's own camera arm is: the line from the two to the camera is traced (the
    -- visibility channel, the two left out), the camera comes in before anything on it at once and goes back out gently,
    -- never past it. And when it starts, the side of the pair (or a higher view) whose line stays clearest through the move;
    -- one that loses its room on the way cuts to another, or stays where it last had room. (The bench, 11-07: "here" on a
    -- river bank it turned into a slope of rock and bush, and the move played behind them on both screens.)
    local CLEAR = { FROM_CM = 60, MARGIN_CM = 35, MIN_CM = 150, OUT_CM_S = 300, LIFT_CM = 170, REPICK_S = 0.25,
        SAMPLES = { 0, 0.3, 0.6, 1 }, NONE = { R = 0, G = 0, B = 0, A = 0 } }

    local function cinemaSpot(a, b, t, side, lift)
        local la, lb = a:K2_GetActorLocation(), b:K2_GetActorLocation()
        local mid = { X = (la.X + lb.X) / 2, Y = (la.Y + lb.Y) / 2, Z = (la.Z + lb.Z) / 2 }
        local e = t * t * (3 - 2 * t)
        local turn = math.atan(lb.Y - la.Y, lb.X - la.X) + side * math.rad(CINE_FROM_DEG + (CINE_TO_DEG - CINE_FROM_DEG) * e)
        local r = CINE_FAR_CM + (CINE_NEAR_CM - CINE_FAR_CM) * e
        local spot = { X = mid.X + math.cos(turn) * r, Y = mid.Y + math.sin(turn) * r,
            Z = mid.Z + CINE_HIGH_CM + (CINE_LOW_CM - CINE_HIGH_CM) * e + (lift or 0) }
        return spot, { X = mid.X, Y = mid.Y, Z = mid.Z - 50 }, mid      -- (aim looks 60 over what it's given)
    end

    -- The line to a camera spot from beside the two (FROM_CM out of their middle toward it: past both bodies): how much of
    -- it is free, where it starts, its length.
    function CLEAR.line(a, b, spot, mid)
        local dx, dy, dz = spot.X - mid.X, spot.Y - mid.Y, spot.Z - mid.Z
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        if len <= CLEAR.FROM_CM + 1 then
            return 0, spot, 0
        end
        local k = CLEAR.FROM_CM / len
        local from = { X = mid.X + dx * k, Y = mid.Y + dy * k, Z = mid.Z + dz * k }
        local free, hit = len - CLEAR.FROM_CM, {}
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if valid(ksl) then
            local ok, got = pcall(function()
                return ksl:LineTraceSingle(a, from, spot, 0, false, { b }, 0, hit, true, CLEAR.NONE, CLEAR.NONE, 0)
            end)
            if ok and got and type(hit.Distance) == "number" then
                free = math.min(free, hit.Distance)
            end
        end
        return free, from, len - CLEAR.FROM_CM
    end

    -- Room on a line for the camera in front of what's on it, MIN_CM from the two's middle at least.
    function CLEAR.roomy(free, full)
        return free >= full or free - CLEAR.MARGIN_CM >= CLEAR.MIN_CM - CLEAR.FROM_CM
    end

    -- How clear a way round the pair stays from t0 on: the free share of its line at a few points of what's left of the move.
    -- A point with no room (the camera would have to go into what's there) counts -1, so a way with one loses to any without.
    -- (The review: averaged, a way into a boulder at the move's end still won.)
    function CLEAR.score(a, b, side, lift, t0)
        local sum = 0
        for _, k in ipairs(CLEAR.SAMPLES) do
            local spot, _, mid = cinemaSpot(a, b, t0 + (1 - t0) * k, side, lift)
            local free, _, full = CLEAR.line(a, b, spot, mid)
            if CLEAR.roomy(free, full) then
                sum = sum + (full > 0 and math.min(1, free / full) or 1)
            else
                sum = sum - 1
            end
        end
        return sum / #CLEAR.SAMPLES
    end

    -- The side given (arena.lua's: toward the arena's middle), else the other, else either from higher up: the clearest from
    -- t0 on, the earlier on a near tie.
    function CLEAR.pick(a, b, side, t0)
        local best, bestSide, bestLift = -math.huge, side, 0
        for _, try in ipairs({ { side, 0 }, { -side, 0 }, { side, CLEAR.LIFT_CM }, { -side, CLEAR.LIFT_CM } }) do
            local s = CLEAR.score(a, b, try[1], try[2], t0 or 0)
            if s > best + 0.05 then
                best, bestSide, bestLift = s, try[1], try[2]
            end
            if best >= 0.99 then
                break
            end
        end
        return bestSide, bestLift, best
    end

    -- One step of the camera, every frame while it plays: coop's frameTicks.cameras. (On game.after's 16 ms loop it moved only
    -- every second or third frame at a high frame rate, a judder at the moment it's there for; the review of 1.7.0.)
    -- False when it has nowhere to be: no room on its line, none on another way round, and no spot it had room at before.
    local cine = nil            -- { run, bodies, from, seconds, side, lift, reach, at, last, repickAt } while one plays
    local function cinemaPlace(cam, a, b, t, c)
        local spot, at, mid = cinemaSpot(a, b, t, c.side, c.lift)
        local free, from, full = CLEAR.line(a, b, spot, mid)
        local now = os.clock()
        -- Something within MIN_CM of the two on its line (the review: the floor put the camera into it): another way round
        -- from here, cut to, looked for at most every REPICK_S.
        if not CLEAR.roomy(free, full) and now >= (c.repickAt or 0) then
            c.repickAt = now + CLEAR.REPICK_S
            local s, lift = CLEAR.pick(a, b, c.side, t)
            if s ~= c.side or lift ~= c.lift then
                local spot2, at2, mid2 = cinemaSpot(a, b, t, s, lift)
                local free2, from2, full2 = CLEAR.line(a, b, spot2, mid2)
                if CLEAR.roomy(free2, full2) then
                    c.side, c.lift, c.reach = s, lift, nil      -- (a cut, as at the start: no sweep through what was there)
                    spot, at, free, from, full = spot2, at2, free2, from2, full2
                end
            end
        end
        if CLEAR.roomy(free, full) then
            -- (In at once; out again at OUT_CM_S, so a branch passing the line doesn't pump it in and out.)
            local want = free < full and free - CLEAR.MARGIN_CM or full
            local reach = c.reach and math.min(want, c.reach + CLEAR.OUT_CM_S * math.max(0, now - c.at)) or want
            c.reach, c.at = reach, now
            if reach < full then
                local k = reach / full
                spot = { X = from.X + (spot.X - from.X) * k, Y = from.Y + (spot.Y - from.Y) * k,
                    Z = from.Z + (spot.Z - from.Z) * k }
            end
            c.last = spot
        elseif c.last then
            spot = c.last       -- (no room anywhere now: it stays where it last had some, still on the two)
        else
            return false
        end
        cam:K2_SetActorLocationAndRotation(spot, aim(spot, at), false, {}, true)
        return true
    end
    local function cinemaTick()
        local c = cine
        if not c then
            return
        end
        if c.run ~= cinemaRun or not valid(cinemaCam) then
            cine = nil
            return
        end
        local t = (os.clock() - c.from) / c.seconds
        local a, b = c.bodies()
        if t >= 1 or not (valid(a) and valid(b)) then
            game.endCinema()
            return
        end
        pcall(cinemaPlace, cinemaCam, a, b, t, c)
    end

    function game.cinema(bodies, seconds, side)
        local pc = api.getPlayer1()
        local a, b = bodies()
        if not (valid(pc) and valid(a) and valid(b)) then
            return false
        end
        local c = { bodies = bodies, seconds = seconds }
        local ok0, s, lift, score = pcall(CLEAR.pick, a, b, side or 1, 0)
        c.side, c.lift = ok0 and s or side or 1, ok0 and lift or 0
        log(string.format("Finishing move's camera: side %d, %s, its way %.2f clear (of 1).", c.side,
            c.lift > 0 and "from higher up" or "level", ok0 and score or 0))
        local spot = cinemaSpot(a, b, 0, c.side, c.lift)
        if not valid(cinemaCam) then
            local t = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = spot, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
            pcall(function()
                local gs = api.gs()
                local cam = gs:BeginDeferredActorSpawnFromClass(pc, StaticFindObject("/Script/Engine.CameraActor"), t,
                    SPAWN_ADJUST_ALWAYS, nil, SCALE_MULTIPLY_WITH_ROOT)
                cinemaCam = gs:FinishSpawningActor(cam, t, SCALE_MULTIPLY_WITH_ROOT)
            end)
            if not valid(cinemaCam) then
                cinemaCam = nil
                return false
            end
            pcall(function() cinemaCam.CameraComponent:SetFieldOfView(CINE_FOV) end)
        end
        local ok = pcall(function()
            if not cinemaPlace(cinemaCam, a, b, 0, c) then
                error("no room")
            end
            pc:SetViewTargetWithBlend(cinemaCam, 0.0, 0, 0, false)     -- (a cut: a blend swept the view across)
        end)
        if not ok then
            log("Finishing move's camera: no room round the two here; each player's own camera shows it.")
        end
        if ok then
            cinemaRun = cinemaRun + 1
            c.run, c.from = cinemaRun, os.clock()
            cine = c
            if api.coop and api.coop.frameTicks then
                game.cinemaTick = cinemaTick        -- (run by coop's frameTicks.cameras: see game.spectate)
            else
                local function loop()
                    if cine then
                        cinemaTick()
                        game.after(0.016, loop)
                    end
                end
                game.after(0.016, loop)
            end
        end
        return ok
    end

    function game.endCinema()
        cinemaRun = cinemaRun + 1
        cine = nil
        game.cinemaTick = nil
        if not valid(cinemaCam) then
            cinemaCam = nil
            return
        end
        local pc, pawn = api.getPlayer1()
        pcall(function()
            local back = (spectating and valid(spectating) and valid(spectateCam)) and spectateCam or pawn
            if valid(pc) and valid(back) then
                pc:SetViewTargetWithBlend(back, 0.0, 0, 0, false)      -- (a cut back too: a blend swept across)
            end
        end)
        local cam = cinemaCam
        cinemaCam = nil
        game.after(0.7, function() if valid(cam) then cam:K2_DestroyActor() end end)
    end
    end

    -- The game's own tip by the gourd at low health ("Press R to use Medicine and recover HP!", W_TutorialBar_Hint_Potion_C)
    -- hidden or shown again: a match hides it while this player is down or beaten (arena.lua), when they can't drink. (Its
    -- widget is always shown, only its bubble comes and goes, so its opacity it is: the bench, 11-07. But only once the game
    -- has made it, as it first shows the tip in a game: one made after a call here comes at full opacity, so arena.lua asks
    -- again while the tip is to stay off.)
    function game.potionHint(show)
        for _, w in ipairs(FindAllOf("W_TutorialBar_Hint_Potion_C") or {}) do
            if valid(w) then
                pcall(function() w:SetRenderOpacity(show and 1.0 or 0.0) end)
            end
        end
    end

    -- rest: test helper, run the game's enemy refresh as if player 1 rested at a bell (the hook sees it).
    game.commands.rest = function()
        local pc = api.getPlayer1()
        local gm = api.gs():GetGameMode(pc)
        local before = #game.listEnemies()
        local ok, err = pcall(function() gm["Refresh Monster"](gm) end)
        log(string.format("Refresh Monster: %s %s (enemies before %d, after %d)", tostring(ok), tostring(err), before,
            #game.listEnemies(true)))
    end

    ------------------------------------------------------------------ bullets

    local BULLET_ACTOR, BULLET_DATA = "/Script/SGameCombatSystem.BulletActorBase", "/Script/SGameCombatSystem.BulletDataBase"

    function game.bulletSystem(pawn)
        return worldSubsystem(pawn, "/Script/SGameCombatSystem.BulletSubsystem")
    end

    -- One this player fired, with a body to see, that no other bullet started.
    function game.isShot(b, owner)
        local ok, yes = pcall(function()
            return b:IsA(lib(BULLET_ACTOR)) and valid(b.BulletOwnerAvatar) and b.BulletOwnerAvatar:GetAddress() == owner
                and b.bWasInitializedWithParentBullet ~= true
        end)
        return ok and yes == true
    end

    function game.isBulletData(d)
        local ok, yes = pcall(function() return d:IsA(lib(BULLET_DATA)) end)
        return ok and yes == true
    end

    local function toQuat(pitch, yaw, roll)
        local p, y, r = math.rad(pitch) / 2, math.rad(yaw) / 2, math.rad(roll) / 2
        local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
        return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy, Z = cr * cp * sy - sr * sp * cy,
            W = cr * cp * cy + sr * sp * sy }
    end

    -- The game's own spawner, on its default object: it holds nothing of a shot's. It only makes the bullet: starting it is the
    -- step that puts it in the world. No ability, as a ghost hasn't got one. Returns true and what it made, as { bullet, name }.
    local PARTICLE_BULLET = "/Script/PBZCombatAsset.PBZ_ParticleBullet"
    function game.fireBullet(owner, data, x, y, z, pitch, yaw, roll)
        local fired = {}
        local ok = pcall(function()
            lib("/Script/SGameCombatSystem.Default__BulletSpawnBurst"):SpawnBullets(owner, nil, nil, data,
                { Rotation = toQuat(pitch, yaw, roll), Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }, fired)
        end)
        if not ok or #fired == 0 then
            return false
        end
        local made = {}
        for i = 1, #fired do
            pcall(function()
                local b = fired[i]:get()
                b:Start()
                local m = { bullet = b, name = b:GetFName():ToString() }
                -- (A particle bullet's look, kept with its name: the bullet can end by its own timer before its end comes from
                -- the sender, and its look, the level's, stayed where it was for good: a Wild Oriole Sword's sword energy.)
                pcall(function()
                    local cls = lib(PARTICLE_BULLET)
                    if valid(cls) and b:IsA(cls) and valid(b.ParticleComponent) then
                        m.fx, m.fxName = b.ParticleComponent, b.ParticleComponent:GetFName():ToString()
                    end
                end)
                made[#made + 1] = m
            end)
        end
        return true, made
    end

    -- A bullet ended the way its own timer ends it. Only the one that was made: by now its address can be another bullet's,
    -- so its name has to match too. A particle bullet's look is a system of its own in the world (the level owns it, not the
    -- bullet), which the ability that fired it turns off: turned off here first, to fade as it does there, or a lion head's
    -- fire burned on with nothing left to end it. (Its field is only asked of a particle bullet.)
    function game.endBullet(made)
        local ok = false
        pcall(function()
            local b = made.bullet
            if valid(b) and b:GetFName():ToString() == made.name then
                pcall(function()
                    local cls = lib(PARTICLE_BULLET)
                    if valid(cls) and b:IsA(cls) then
                        local fx = b.ParticleComponent
                        if valid(fx) then
                            fx:Deactivate()
                        end
                    end
                end)
                -- (And the bullet's own record of its looks, any kind: a projectile keeps them there, and its timer's end
                -- skips the Deactivate that turns them off, so one placed in the world stayed where the copy was cut: the
                -- Wild Oriole's sword energy that "stays in place and never goes away" may be this. Said once a kind.)
                pcall(function()
                    local n = 0
                    b.EffectInstanceData.InstanceData:ForEach(function(_, v)
                        v:get().NiagaraComponents:ForEach(function(_, e)
                            local c = e:get()
                            if valid(c) and c:IsActive() then
                                c:Deactivate()
                                n = n + 1
                            end
                        end)
                    end)
                    if n > 0 then
                        game.saidLooks = game.saidLooks or {}
                        local kind = b:GetClass():GetFName():ToString()
                        if not game.saidLooks[kind] then
                            game.saidLooks[kind] = true
                            log("A copied bullet (" .. kind .. ") ended with " .. n .. " of its looks on: turned off.")
                        end
                    end
                end)
                b:OnTimeToDestroy()
                ok = true
            end
        end)
        -- The bullet gone already (its own timer): its look may not be. Turned off, if it's still that one.
        pcall(function()
            local fx = made.fx
            if valid(fx) and fx:GetFName():ToString() == made.fxName and fx:IsActive() then
                fx:Deactivate()
                ok = true
            end
        end)
        return ok
    end

    -- True once a copy's bullet is over here (gone, or its address another's), its look left on maybe.
    function game.bulletOver(made)
        local ok, over = pcall(function()
            local b = made.bullet
            return not (valid(b) and b:GetFName():ToString() == made.name)
        end)
        return ok and over
    end

    ------------------------------------------------------------------ currency (dust)

    -- Dust gained locally (kill rewards, pickups) goes to the other player too: shared rewards. Spending isn't
    -- mirrored. Amounts the mod itself added for the other player are not sent back.
    local lastDust, syncedDust = nil, 0

    local function dust(pawn)
        local ok, v = pcall(function() return pawn.ConsciousnessDust end)
        return ok and tonumber(v) or nil
    end

    -- Only what was earned goes out: a rise across a new body (a respawn, a trip to a partner, a load: the dust read low, then
    -- the saved amount back) or while down isn't, and the count starts again from there. Each was sent whole
    -- as a gain and paid to everyone, over and over (player report 11-09: three players, an hour, 600k and 1.5m).
    game.dustWatch = { addr = nil, quietUntil = 0, QUIET_S = 10, AFTER_DOWN_S = 5 }
    function game.watchCurrency(pawn, sendEvent)
        local d = dust(pawn)
        if d == nil then
            return
        end
        local w, now = game.dustWatch, os.clock()
        local addr = pawn:GetAddress()
        if addr ~= w.addr then
            w.quietUntil = w.addr and now + w.QUIET_S or w.quietUntil     -- (a new body, not the first one seen)
            w.addr = addr
        end
        -- (Not a scene: a boss's dust comes in its death scene, and the partners' share of it was lost.)
        local down = game.isDead(pawn)
        if down then
            w.quietUntil = math.max(w.quietUntil, now + w.AFTER_DOWN_S)     -- (and a while after getting up: a respawn here
            -- takes 3 s and keeps the body, so a wallet given back with it came after it)
        end
        local still = down or now < w.quietUntil
        if lastDust ~= nil and not still then
            local gained = d - lastDust - syncedDust
            if gained > 0 then
                sendEvent("C", gained)
            end
        end
        lastDust, syncedDust = d, 0
    end

    function game.addCurrency(pawn, amount)
        if not valid(pawn) or amount <= 0 then
            return
        end
        local ok = pcall(function() pawn:ChangeDustNumInternal(amount) end)
        if ok then
            syncedDust = syncedDust + amount
            if game.downAt then
                game.downAt.shared = game.downAt.shared + amount     -- (no pay of a boss's: game.payOwed)
            end
            log("Shared dust: +" .. amount)
        end
    end

    ------------------------------------------------------------------ items

    local watched = {}            -- pickup name -> { itemId } for pickups near the local player last tick
    local takenHere = {}          -- pickup name -> true once the local player took it (until the next bell rest)
    game.goneHere = {}            -- save and map -> { pickup name -> who }: what a partner took (game.takeRemotePickup)
    game.nearPickups = {}         -- pickup name -> { item, at }: those out of the look's reach but within a run, last look
    game.saveSlot = nil           -- the save this world is (its slot), read as each map comes: goneHere is that save's alone

    -- goneHere's key for a map: this save's and that map's. (Not across saves: another one loaded in the same game had every
    -- pickup a partner took on its maps gone with nothing given; the review of 11-09.)
    function game.goneKey(map)
        return map and ((game.saveSlot or "") .. "|" .. tostring(map)) or nil
    end

    -- The save this world is, from the game's save system: game.saveSlot, read as a map comes, or by a partner's word that
    -- came first. (Before this world's first look, as it loads in, a word filed what was taken under no save, and the copy
    -- that came back after, looked for under the save's name, was there to take again: the review of 11-10.)
    function game.readSaveSlot()
        pcall(function()
            local sys = FindFirstOf("PBZSaveLoadSubsystem")
            if valid(sys) then
                local s = sys:GetContinueSlotName()
                pcall(function() s = s:ToString() end)
                game.saveSlot = type(s) == "string" and s or game.saveSlot
            end
        end)
        return game.saveSlot
    end

    local function pickupItemId(p)
        local ok, id = pcall(function() return p.ItemId:ToString() end)
        return ok and id or "?"
    end

    -- Called every few snapshots: pickups that were next to the local player and are now gone were taken by
    -- them. "Gone" includes a destroyed pickup that FindAllOf still returns (it stays valid until garbage
    -- collection, but loses its position) and one the game marked unpickable.
    -- After a map change (or while the pickups are unloaded mid-load: FindAllOf finds none at all) the watched
    -- pickups vanished because the level went away, not because the player took them: report nothing then.
    -- They stay where they are, so each is read once, a few a time, and only those near the player are looked at again.
    local PICKUP_JUMP_CM = 1000
    local NEW_PICKUPS_PER_PASS = 16
    local watchedMap = nil
    local pickupSpots = {}        -- pickup address -> { name, loc }
    function game.watchPickups(pawn, report)
        game.pickupReport = report    -- (game.takeRemotePickup tells one this look won't)
        if not maySearch() then
            return false          -- the caller comes back in a tenth of a second
        end
        searched()
        local here = pawn:K2_GetActorLocation()
        local all = FindAllOf("PBZPickupActor") or {}
        local map = game.mapName(pawn)
        if map ~= watchedMap or (#all == 0 and (next(watched) ~= nil or next(game.nearPickups) ~= nil)) then
            if map ~= watchedMap then
                takenHere = {}    -- pickup names are only unique within a map
                pickupSpots = {}
                game.readSaveSlot()
            end
            watchedMap = map
            watched, game.nearPickups = {}, {}
        end
        local present, spots, newOnes = {}, {}, 0
        local gone = game.goneHere[game.goneKey(api.coop and api.coop.net.localMap or map)]
        for _, p in ipairs(all) do
            local addr = p:GetAddress()
            local spot = pickupSpots[addr]
            if spot == nil and newOnes < NEW_PICKUPS_PER_PASS and valid(p) then
                newOnes = newOnes + 1
                local okL, loc = pcall(function() return p:K2_GetActorLocation() end)
                if okL and loc.X then
                    spot = { name = p:GetFName():ToString(), loc = loc }
                    -- (One the partner took, made again as its area streamed back in, or loaded after their word came: gone
                    -- again. See game.takeRemotePickup.)
                    if gone and gone[spot.name] then
                        pcall(function() p:K2_DestroyActor() end)
                        spot.gone = true
                        log("A pickup the other player took was here again (" .. spot.name .. "): gone again.")
                    end
                end
            end
            spots[addr] = spot
            if spot and not spot.gone and (watched[spot.name] or distance(spot.loc, here) <= PICKUP_WATCH_CM + PICKUP_JUMP_CM)
                and valid(p) then
                local okP, pickable = pcall(function() return p.bIsPickable end)
                local okL, loc = pcall(function() return p:K2_GetActorLocation() end)
                if (not okP or pickable ~= false) and okL and loc.X then
                    present[spot.name] = { actor = p, loc = loc, spot = spot }
                end
            end
        end
        pickupSpots = spots
        -- (Here from far off since the last look, a respawn, a bell trip or F3 on the same map: what's gone went with the
        -- streaming, not into this player's hands. Told as taken, the partner's copy was destroyed and nobody had the thing;
        -- the review of the item reports, 1.6.6.)
        local last = game.pickupsAt
        local jumped = last ~= nil and distance(last.loc, here) > math.max(PICKUP_JUMP_CM, 2000 * (os.clock() - last.t))
        game.pickupsAt = { loc = { X = here.X, Y = here.Y, Z = here.Z }, t = os.clock() }
        for name, info in pairs(watched) do
            local now = present[name]
            if now == nil or distance(now.loc, info.loc) > PICKUP_JUMP_CM then
                if not jumped then
                    takenHere[name] = true
                    -- (Only loot known to be loot: a pickup whose item couldn't be read, or read before the item table was,
                    -- went out as loot, and the partner's copy of a quest item (the Snake Tongue, a token half) vanished
                    -- with nothing given, their quest stuck: issue #15.)
                    local quest = game.keptApart(info.itemId)
                    if not quest and info.itemId ~= "?" and info.itemId ~= "None" and game.narrative ~= nil then
                        report(name, info.itemId)
                    end
                end
                present[name] = nil
            end
        end
        -- (Gone since the last look from within a run of this player, out of the look's reach then, with its thing given here
        -- since: this player ran to it and took it between two looks. Untold, a partner who took it too gave a third player
        -- two; and taken for a copy not loaded at the partner's word, theirs came here as a second: the review of 11-10.)
        for name, info in pairs(game.nearPickups) do
            local given = game.lastGiven[info.item]
            if present[name] == nil and not takenHere[name] and not jumped and given and given.at >= info.at then
                takenHere[name] = true
                if not game.keptApart(info.item) and game.narrative ~= nil then
                    report(name, info.item)
                end
            end
        end
        watched, game.nearPickups = {}, {}
        for name, p in pairs(present) do
            if distance(p.loc, here) <= PICKUP_WATCH_CM then
                watched[name] = { itemId = pickupItemId(p.actor), loc = p.loc }
            else
                p.spot.item = p.spot.item or pickupItemId(p.actor)      -- (read once a pickup)
                if p.spot.item ~= "?" and p.spot.item ~= "None" then
                    game.nearPickups[name] = { item = p.spot.item, at = os.clock() }
                end
            end
        end
    end

    -- The other player took this pickup: remove our copy and give us the same item, so loot is shared. map: the map it
    -- lies on, as they said it (net's map id), or nil; from: who (a party's slot), or nil; held, n: what a ground pickup held
    -- and how many their game gave, as they said it, or nil.
    function game.takeRemotePickup(name, itemId, pawn, kind, map, from, held, n)
        if takenHere[name] then
            -- Both players grabbed it within the same moment: each already has theirs, as in single-player.
            log("The other player took " .. name .. " too; you already have yours.")
            return
        end
        -- A quest item stays for this player to pick up. (A ground pickup comes as "?", only that it's gone: the sender
        -- tells loot alone, see watchPickups.)
        if itemId and itemId ~= "?" and game.keptApart(itemId) then
            log("The other player took " .. name .. " (" .. tostring(itemId) .. "): a quest item, left here for you to take.")
            return
        end
        -- (A ground pickup's gone for good while the session lasts, on this save: a copy destroyed was made again when its area
        -- streamed back in, a bell trip away and back, and lay there to be taken a second time; nor was one loaded after this
        -- word came ever taken. A report on 1.6.9. watchPickups. Another partner's word for one gone here already: their
        -- share is the same thing, noted to be one each (receiveGift): two guests who took one gave the host two, the review
        -- of 11-09. The same partner's word again is theirs come back in their world: its share theirs, the review of 11-10.)
        local ground = itemId == "?"
        held = held ~= "-" and held ~= "?" and held ~= "None" and held or nil
        if ground and game.saveSlot == nil then
            game.readSaveSlot()
        end
        local key = game.goneKey(map or (api.coop and api.coop.net.localMap) or watchedMap)
        if ground and key then
            local gone = game.goneHere[key]
            local by = gone and gone[name]
            if by then
                if held and by ~= (from or true) then
                    game.dupShares[#game.dupShares + 1] = { id = held, count = n, from = from, at = os.clock() }
                end
                return
            end
            game.goneHere[key] = gone or {}
            game.goneHere[key][name] = from or true
        end
        -- (This player took it too, in the same moment: the word here before this world's own look told takenHere. Each has
        -- theirs, and the partner's share is "given here too": waited for, it came as a second, the review of 11-09. Told
        -- the others as the look tells a take, that look only telling one in reach at the look before: a third player's
        -- share of it is the same thing then. Untold, the host got two: the review of 11-10.)
        local function mineToo(item)
            takenHere[name] = true
            log("The other player took " .. name .. " too; you already have yours.")
            if not watched[name] and game.pickupReport and item and item ~= "?" then
                game.pickupReport(name, item)
            end
        end
        local found = false
        for _, p in ipairs(FindAllOf("PBZPickupActor") or {}) do
            if valid(p) and p:GetFName():ToString() == name then
                found = true
                -- (Ours taken already: unpickable, or moved off its spot, destroyed and found still till it's collected.)
                local okP, pickable = pcall(function() return p.bIsPickable end)
                local spot = pickupSpots[p:GetAddress()]
                local okL, loc = pcall(function() return p:K2_GetActorLocation() end)
                local item = pickupItemId(p)
                if (okP and pickable == false) or (spot and spot.name == name and okL and loc and loc.X
                    and distance(loc, spot.loc) > PICKUP_JUMP_CM) then
                    mineToo(item ~= "?" and item or held)
                    return
                end
                watched[name] = nil
                -- (Gone first: a fault in what follows had left our copy there to take, the review of 11-10. Its item comes
                -- by T: what it held is waited for.)
                p:K2_DestroyActor()
                if ground then
                    game.awaitShare(item ~= "?" and item or held, n, from)
                end
                break
            end
        end
        -- (Our copy not loaded when the word came: what it held comes with the word, waited for all the same. Else its share
        -- met the 15 s checks, dropped there if this world had the same thing lately, and the copy was destroyed as it
        -- loaded: nothing given at all. The review of 11-09. But one this world had loaded within a run of this player at its
        -- last look, gone since, with its thing just given here: this player took it too, the word before the next look.
        -- One each, as above; waited for, the partner's share came as a second, the review of 11-10.)
        if ground and not found and held then
            local mine = game.lastGiven[held]
            if mine and os.clock() - mine.at < 5 and (watched[name] or game.nearPickups[name]) then
                mineToo(held)
                return
            end
            game.awaitShare(held, n, from)
        end
        if itemId and itemId ~= "?" then
            game.grantLoot(pawn, itemId, kind)
        end
    end

    ------------------------------------------------------------------ enemy groups

    -- A group of enemies gets its places from SGameAIMathUtils:SolveAssignment, which never comes back if a place is the
    -- engine's "no location" value, and the whole game hangs. A formation gets that when its search for a spot fails and the
    -- blackboard key it falls back on was never set, which a boss running on with its target down can reach. Such a place
    -- becomes where that enemy already stands.
    local SOLVER = "/Script/SGameAI.SGameAIMathUtils:SolveAssignment"
    local MAP_EDGE_CM = 1e9
    local solverGuarded, solverTold = false, false

    local function onMap(v)
        return math.abs(v.X) < MAP_EDGE_CM and math.abs(v.Y) < MAP_EDGE_CM and math.abs(v.Z) < MAP_EDGE_CM
    end

    local function standingSpots(actors)
        local spots = {}
        actors:get():ForEach(function(i, element)
            local actor = element:get()
            if valid(actor) then
                spots[i] = actor:K2_GetActorLocation()
            end
        end)
        return spots
    end

    function game.guardFormations()
        if solverGuarded or not valid(StaticFindObject(SOLVER)) then
            return
        end
        solverGuarded = true
        local ok, err = pcall(function()
            RegisterHook(SOLVER, function(_, actors, goals)
                local spots = nil
                goals:get():ForEach(function(i, element)
                    local goal = element:get()
                    if not onMap(goal) then
                        spots = spots or standingSpots(actors)
                        local at = spots[i] or spots[1]
                        goal.X, goal.Y, goal.Z = at and at.X or 0, at and at.Y or 0, at and at.Z or 0
                    end
                end)
                if spots and not solverTold then
                    solverTold = true
                    log("An enemy group was given no place to go: it stays where it stands.")
                end
            end)
        end)
        if not ok then
            log("Enemy group guard is off: " .. tostring(err))
        end
    end

    ------------------------------------------------------------------ what the game gives

    -- Whatever the game gives one player, the other gets too: the same items, at any distance, wherever they came from. So
    -- it's the backpack's own ways in that are watched. Not what a player buys or makes, nor what this mod adds. The same
    -- thing given on both PCs within a moment (a boss's reward, a chest both opened) stays one each.
    local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
    local SAME_GIFT_S = 15
    local OWN_ITEM_S = 0.2          -- what comes this soon after buying or making something is that
    local GEAR = { MedicineInfos = "medicine", Accessories = "accessory" }
    local givenHere, gearKnown, ownUntil = {}, nil, 0
    local gotFrom = {}              -- with more than two players: what came from whom, and when
    local giftsHooked = false

    local function given(id, count, kind, send)
        -- (Nor in a PvP match: there's no loot in one, and what it adds, a lent weapon, is the match's own: the bench, 11-08.)
        if game.granting or os.clock() < ownUntil or id == "None" or count < 1 or game.keptApart(id)
            or (api.arena and api.arena.match) then
            return
        end
        givenHere[id .. "x" .. count] = os.clock()
        game.lastGiven[id] = { n = count, at = os.clock() }
        send(id, count, kind or "-")
    end

    -- How many of id the game just gave this player (its pickup's word says it: game.takeRemotePickup), else 1.
    game.lastGiven = {}
    function game.pickupCount(id)
        local g = game.lastGiven[id]
        return (g and os.clock() - g.at < 3) and g.n or 1
    end

    function game.hookGifts(send)
        if giftsHooked or not valid(StaticFindObject(BACKPACK)) then
            return
        end
        giftsHooked = true
        local ok, err = pcall(function()
            RegisterHook(BACKPACK .. ":AddPropsByMap", function(_, map, push)
                if push:get() then
                    map:get():ForEach(function(id, count)
                        given(id:get():ToString(), count:get(), nil, send)
                    end)
                end
            end)
            RegisterHook(BACKPACK .. ":AddPropsToBackPack", function(_, count, id, push)
                if push:get() then
                    given(id:get():ToString(), count:get(), nil, send)
                end
            end)
            RegisterHook(BACKPACK .. ":AddWeaponItem", function(_, id, normal, _push, loading)
                if not loading:get() then
                    given(id:get():ToString(), 1, normal:get() and "weapon" or "weapon2", send)
                end
            end)
            for _, fn in ipairs({ ":BuyItem", ":CraftItem", ":AutoCheckCrafting" }) do
                RegisterHook(BACKPACK .. fn, function()
                    ownUntil = os.clock() + OWN_ITEM_S
                end)
            end
        end)
        if not ok then
            log("Shared items are off: " .. tostring(err))
        end
    end

    -- A drink: the game counts it, then applies it. (localcoop.lua decides whose it is.)
    local medicineHooked = false
    function game.hookMedicine(counted, before, after)
        if medicineHooked or not valid(StaticFindObject(BACKPACK)) then
            return
        end
        medicineHooked = true
        local ok, err = pcall(function()
            local drunk = nil
            RegisterHook(BACKPACK .. ":UseMedicine", function(_, id)
                drunk = id:get():ToString()
            end)
            RegisterHook(BACKPACK .. ":ActivateMedicineGameplayEffect", function()
                counted(drunk)
                before()
            end, function()
                after()
            end)
        end)
        if not ok then
            log("Player 2's drinks stay player 1's: " .. tostring(err))
        end
    end

    -- Medicines and accessories have no one way in: the lists themselves are looked at, every few seconds.
    function game.watchGear(pawn, send)
        local bp = worldSubsystem(pawn, BACKPACK)
        if not bp then
            return
        end
        local first = gearKnown == nil
        gearKnown = gearKnown or {}
        for list, kind in pairs(GEAR) do
            pcall(function()
                bp[list]:ForEach(function(key)
                    local id = key:get():ToString()
                    if not gearKnown[id] then
                        gearKnown[id] = true
                        if not first then
                            given(id, 1, kind, send)
                        end
                    end
                end)
            end)
        end
    end

    -- from: who it came from, with more than two players: two partners given the same thing in a moment are one thing too.
    -- more: another share of the same thing is still on its way here (coop.lua's takeGifts); at: when this one came.
    function game.receiveGift(pawn, id, count, kind, from, more, at)
        if game.keptApart(id) then
            return          -- (a quest item, with the old rule: each player picks up their own, see game.keptApart)
        end
        local key, now = id .. "x" .. count, os.clock()
        -- (A second partner's share of one pickup, gone here already at the first one's word: the same thing, one each.)
        if game.takeDupShare(id, from, count) then
            log("Two players took the same pickup of " .. id .. ": one each.")
            return
        end
        local here = givenHere[key]
        -- (The share of a ground pickup of the partner's: our copy went with their word, so nothing here gave it, whatever
        -- this world was given lately: two players finding the same herb in a moment lost one. game.awaitShare. But a share
        -- of what this world gave as it came, not as many as the pickup held (or, not knowing that, with another share of
        -- it still on its way), is that event's (a kill's reward both games give): given here too, the wait left for the
        -- pickup's own. The review of 11-09: a kill's reward took a pickup's wait, and the pickup's share came on top. Only
        -- as it came: their word's count is their game's last give of the thing, and a reward between their take and their
        -- look gave it the reward's; this world's own find of a while before took the pickup's share for it then, the
        -- review of 11-10.)
        local wait = game.pickupWaitFor(id, from, count)
        if wait and here and now - here < SAME_GIFT_S and here >= (at or now) - game.SAME_EVENT_S then
            local w = game.pickupShares[wait]
            if (w.count and w.count ~= count) or (not w.count and more) then
                wait = nil
            end
        end
        local pickup = nil
        if wait then
            pickup = table.remove(game.pickupShares, wait).given and "given" or "wanted"
        end
        if pickup == "given" then
            log("The share for " .. id .. " came after it was given from the pickup here: one each.")
            return
        end
        if pickup == nil and here and now - here < SAME_GIFT_S then
            log("The game gave " .. id .. " here too: one each.")
            return
        end
        if from and pickup == nil then
            local last = gotFrom[key]
            if last and last.from ~= from and now - last.at < SAME_GIFT_S then
                log("Two players got " .. id .. ": one each.")
                return
            end
            gotFrom[key] = { from = from, at = now }
        end
        if gearKnown then
            gearKnown[id] = true
        end
        if pickup == nil then
            -- (Old ones off as each comes: only a ground pickup's word took them off, and with none for long the list grew
            -- by every share; the review of 11-10.)
            for i = #game.sharesGiven, 1, -1 do
                if now - game.sharesGiven[i].at >= game.PICKUP_SHARE_S then
                    table.remove(game.sharesGiven, i)
                end
            end
            game.sharesGiven[#game.sharesGiven + 1] = { id = id, from = from, at = now }
        end
        game.grantLoot(pawn, id, kind, count)
    end

    -- A ground pickup the partner took, our copy gone (game.takeRemotePickup): what it held is waited for. Its share (T)
    -- is given whatever was given here lately (receiveGift). One that doesn't come in PICKUP_SHARE_S is given from the
    -- copy's item, and a share after that is dropped: their game may have taken it in without its notice, and with our
    -- copy gone for good (watchPickups), nothing here had it at all (a report on 1.6.9: "the host doesn't actually get
    -- it"). A share given here just before the word came was this one's. (Fields: this file is at its 200 locals.)
    game.pickupShares, game.sharesGiven, game.dupShares = {}, {}, {}
    game.PICKUP_SHARE_S = 16        -- (past the 12 s a share waits out a scene: coop.lua's takeGifts)
    game.SAME_EVENT_S = 3           -- this world's own give this long before a share came is the same event's
    -- (A partner's: their share alone answers it, where who it is is known. count: how many their game gave, for the copy's.)
    function game.awaitShare(id, count, from)
        if type(id) ~= "string" or id == "?" or id == "None" then
            return
        end
        local now = os.clock()
        -- (Old ones off first, then the look: taken off below the one found as it went, its place pointed past the list,
        -- and the word stopped there, our copy still to take. The review of 11-10.)
        for i = #game.sharesGiven, 1, -1 do
            if now - game.sharesGiven[i].at >= game.PICKUP_SHARE_S then
                table.remove(game.sharesGiven, i)
            end
        end
        for i = #game.sharesGiven, 1, -1 do
            local s = game.sharesGiven[i]
            if s.id == id and (from == nil or s.from == nil or s.from == from) then
                table.remove(game.sharesGiven, i)    -- (its share came first: given already)
                return
            end
        end
        game.pickupShares[#game.pickupShares + 1] = { id = id, count = count, from = from, at = now }
    end

    -- The ground pickup waited for that a share of id (count of it) from this partner answers: one still waiting for as
    -- many first, then one still waiting, then one given from the copy already (a share after that is dropped). Its index
    -- in pickupShares, or nil.
    function game.pickupWaitFor(id, from, count)
        local other, given = nil, nil
        for i, s in ipairs(game.pickupShares) do
            if s.id == id and (from == nil or s.from == nil or s.from == from) then
                if s.given then
                    given = given or i
                elseif count == nil or s.count == nil or s.count == count then
                    return i
                else
                    other = other or i
                end
            end
        end
        return other or given
    end

    -- A second word of another partner's for one pickup gone here (game.takeRemotePickup): their share of it, now, is the same
    -- thing. True (and taken off the list) if this is that: as many as their word said. (By item alone, a find of theirs of
    -- the same thing just before their take was taken for it, and the pickup's own share came as a thing of its own: the
    -- review of 11-10.)
    function game.takeDupShare(id, from, count)
        local now = os.clock()
        for i = #game.dupShares, 1, -1 do
            local d = game.dupShares[i]
            if now - d.at >= SAME_GIFT_S then
                table.remove(game.dupShares, i)
            elseif d.id == id and (from == nil or d.from == nil or d.from == from)
                and (count == nil or d.count == nil or d.count == count) then
                table.remove(game.dupShares, i)
                return true
            end
        end
        return false
    end

    -- The waits run out: given from the copy's item (a thing of the game's item table: a weapon or a piece of gear comes its
    -- own way), kept a while longer as given. Not in a scene: a share waits one out.
    function game.pickupSharesDue(pawn)
        local now, kept = os.clock(), {}
        local scene = game.inCutscene and game.inCutscene()
        for _, s in ipairs(game.pickupShares) do
            local age = now - s.at
            if age < game.PICKUP_SHARE_S or (scene and not s.given) then
                kept[#kept + 1] = s
            elseif s.given then
                if age < 2 * game.PICKUP_SHARE_S then
                    kept[#kept + 1] = s
                end
            elseif game.itemKinds and game.itemKinds[s.id] then
                log("The share of " .. s.id .. " the other player picked up never came: given from the pickup here.")
                game.grantLoot(pawn, s.id, nil, s.count or 1)
                s.given, s.at = true, now
                kept[#kept + 1] = s
            end
        end
        game.pickupShares = kept
    end

    -- On linking, the two bags come to the most of each (the user: "they adjust to the one that has more so no one
    -- loses"): weapons, Phantom Edges, accessories and medicines one has, the other gets; a thing that's counted comes to
    -- the higher count, never the two added; quest things too, the quests themselves going both ways (story.lua). Not
    -- dust. After that, what anyone finds comes to both as it always did. (No locals here: this file is at its 200.)
    -- An entry is "kind:id:count", kind w (weapon) e (Phantom Edge) a (accessory) m (medicine) p (counted).
    function game.bagSummary(pawn)
        local bp = valid(pawn) and worldSubsystem(pawn, BACKPACK)
        local out = {}
        if not bp then
            return out
        end
        for list, kind in pairs({ MainWeaponInfos = "w", ShaqiWeaponInfos = "e", Accessories = "a", MedicineInfos = "m" }) do
            pcall(function()
                bp[list]:ForEach(function(k)
                    out[#out + 1] = kind .. ":" .. k:get():ToString() .. ":1"
                end)
            end)
        end
        pcall(function()
            bp.Inventories:ForEach(function(k, v)
                local n = v:get().CurrentAmount
                local id = k:get():ToString()
                if type(n) == "number" and n > 0 and not game.keptApart(id) then
                    out[#out + 1] = "p:" .. id .. ":" .. math.floor(n)
                end
            end)
        end)
        return out
    end

    -- What this player holds: id -> count, gear and quest things too. (game.noteDown, game.payOwed)
    function game.holding(pawn)
        local bp = valid(pawn) and worldSubsystem(pawn, BACKPACK)
        local out = {}
        if not bp then
            return nil
        end
        for _, list in ipairs({ "MainWeaponInfos", "ShaqiWeaponInfos", "Accessories", "MedicineInfos" }) do
            pcall(function()
                bp[list]:ForEach(function(k)
                    out[k:get():ToString()] = 1
                end)
            end)
        end
        pcall(function()
            bp.Inventories:ForEach(function(k, v)
                local n = v:get().CurrentAmount
                if type(n) == "number" and n > 0 then
                    out[k:get():ToString()] = math.floor(n)
                end
            end)
        end)
        return out
    end

    -- A boss of this world that died while this player was down: a partner's blow killed it, this player's respawn held
    -- for the fight (a report on 1.7.1, three players: "if host dies during fight, they don't get items"). On the bench
    -- (11-12) the game paid a player down the boss's dust and kept it after the respawn, but the dust watch shares no rise
    -- while down, so the partners never got their share; a game that paid nobody who's down is covered too. So the bag and
    -- wallet at the death are kept (noteDown), the boss's pay is owed (oweBoss: its loot table, as rollLoot rolls it for
    -- the partners), they're read each turn till it's settled (watchOwed), and once this player is up and settled
    -- (payOwed) the game's own pay, if it came, goes to the partners as at a live kill; else each thing it lacks of that
    -- pay is given: never more than the boss's own, no other loss made good.
    -- fight: the names of the bosses of the fight this player went down in (coop's watchOwnDeath), or nil.
    -- (shared: the partners' shares since the death, no pay of a boss's; best: the most the wallet rose by since the death
    -- in a read, those shares not counted; stillBest: the same, in reads while the dust watch holds gains back, down or in
    -- its quiet just after; bagBest: the most of each thing held in a read.)
    function game.noteDown(pawn, fight)
        if game.owedBosses then
            return          -- (down again before it was paid: that death's bag stays the one to go by)
        end
        game.downAt = { held = game.holding(pawn) or {}, dust = dust(pawn) or 0, shared = 0, bagBest = {}, fight = fight or {} }
    end

    -- Whether a death here now, this player down, is a boss's to owe: one by the mod's word (boss), or one of the fight they
    -- went down in. (The game takes the bar down as its player dies, and a boss the codex doesn't call one, the gold-masked
    -- man of the first map, was then a boss to nobody: on the bench, 11-12, nothing of his was owed.)
    function game.downBoss(name, boss)
        local was = game.downAt
        if was == nil or was.up then
            return false
        end
        return boss and true or was.fight[name] == true
    end

    function game.oweBoss(name, dustPaid, items)
        if game.downAt and not game.downAt.up then
            game.owedBosses = game.owedBosses or {}
            table.insert(game.owedBosses, { name = name, dust = tonumber(dustPaid) or 0, items = items or {} })
            game.owedNames = game.owedNames or {}
            game.owedNames[name] = os.clock()       -- (and its win's steps from a guest's world: flowsync.lua's DB)
        end
    end

    -- A boss owed that got up again (coop's shareEnemy): its fall was a phase's (Xiaoxue's), no win, and nothing of it is
    -- owed. (Owed, the host was paid a boss's dust for the fall, and the partners a share of it: the review of the draft.)
    function game.dropOwed(name)
        if game.owedNames then
            game.owedNames[name] = nil
        end
        for i = #(game.owedBosses or {}), 1, -1 do
            if game.owedBosses[i].name == name then
                table.remove(game.owedBosses, i)
            end
        end
        if game.owedBosses and #game.owedBosses == 0 then
            game.owedBosses = nil
        end
    end

    -- A boss owed, down or up till it's settled: the wallet's rise since the death and the bag, the most of each kept. The
    -- most, not the last: spending only lowers it, so dust spent at the bell after the respawn isn't a pay lost (read once
    -- up, it was given back: the review), a pay that comes late is seen before it's spent, and the dust can read low for a
    -- moment as a respawn starts (the dust watch's own note). A share comes with its own count, so it's never the pay.
    function game.watchOwed(pawn)
        local was = game.downAt
        if not (was and game.owedBosses) then
            return
        end
        local wallet = dust(pawn)
        if wallet then
            local rise = wallet - was.dust - was.shared
            was.best = math.max(was.best or rise, rise)
            if game.isDead(pawn) or os.clock() < game.dustWatch.quietUntil then
                was.stillBest = math.max(was.stillBest or rise, rise)
            end
        end
        if os.clock() >= (was.bagAt or 0) then
            was.bagAt = os.clock() + 1.0
            for id, n in pairs(game.holding(pawn) or {}) do
                was.bagBest[id] = math.max(was.bagBest[id] or 0, n)
            end
        end
    end

    -- What's owed against what came: { kept, rise, now, want, cash }, or nil while it can't be told (no body, or no wallet
    -- or bag to read yet: read as empty, all of it was given). kept: the game's own pay came here (its dust, at least half:
    -- it's rolled; or a counted thing of it, all of it): nothing is given, a second roll would only add to it.
    function game.owedState(pawn)
        local owed, was = game.owedBosses, game.downAt
        local bag = owed and was and game.holding(pawn)
        local wallet = bag and dust(pawn)
        if not wallet or (next(bag) == nil and next(was.held) ~= nil) then
            return nil
        end
        local rise = math.max(was.best or -math.huge, wallet - was.dust - was.shared)
        local now = {}
        for id, n in pairs(bag) do
            now[id] = n
        end
        for id, n in pairs(was.bagBest) do
            now[id] = math.max(now[id] or 0, n)
        end
        local want, cash = {}, 0
        for _, boss in ipairs(owed) do
            cash = cash + boss.dust
            for _, it in ipairs(boss.items) do
                if it.id:find("^[RI]_%d") then
                    -- (Notes and keys aren't counted in the bag: one kept can't be told from one lost. Not given.)
                elseif it.kind and it.kind ~= "-" then
                    want[it.id] = { n = 1, kind = it.kind }
                else
                    want[it.id] = { n = ((want[it.id] or {}).n or 0) + it.count }
                end
            end
        end
        local kept = cash > 0 and rise >= cash / 2
        for id, w in pairs(want) do
            kept = kept or (not w.kind and (now[id] or 0) >= (was.held[id] or 0) + w.n)
        end
        return { kept = kept, rise = rise, now = now, want = want, cash = cash, was = was }
    end

    -- Down again before what was owed was settled, the game's pay not come (coop's watchOwnDeath): this down is the last
    -- one's again, so a boss of this fight is owed too (fight: its names), and what's lacking is given once they're up.
    -- (Settled with nothing given to a player down, the dust watch holding it back, it was lost: the review.)
    function game.reopenDown(fight)
        if game.downAt then
            game.downAt.up = false
            for name in pairs(fight or {}) do
                game.downAt.fight[name] = true
            end
        end
    end

    -- Settles what's owed: returns the words for what was given ({} for nothing), the partners' share of the game's own pay
    -- kept here (coop's to send as C: it went nowhere while down), and whether it was kept; nil while it can't be told.
    function game.payOwed(pawn)
        local st = game.owedState(pawn)
        if not st then
            return nil
        end
        local was, want, now = st.was, st.want, st.now
        game.owedBosses, game.downAt = nil, nil
        if st.kept then
            -- (The partners' share: the rise while the dust watch held gains back, down or just up; one that came later
            -- went to them as earned already. The review: counted from the dust watch's steps, a low read and the
            -- wallet back was taken for a gain.)
            return {}, math.max(0, math.min(st.cash, was.stillBest or 0)), true
        end
        local paid = {}
        for id, w in pairs(want) do
            -- (Gear is had or not; a counted thing up to what it was at the death and the boss's count on top.)
            local lack = w.kind and ((now[id] or 0) > 0 and 0 or 1)
                or math.min(w.n, (was.held[id] or 0) + w.n - (now[id] or 0))
            if lack > 0 then
                game.grantLoot(pawn, id, w.kind, lack)
                paid[#paid + 1] = id .. " x" .. lack
            end
        end
        local lack = math.min(st.cash, st.cash - math.max(st.rise, 0))
        if lack > 0 and pcall(function() pawn:ChangeDustNumInternal(lack) end) then
            paid[#paid + 1] = lack .. " dust"
        end
        return paid, 0, false
    end

    -- A quest item ("NarrativeItem" in the game's item table: keys, the Flesh Flower, letters): never shared. Each player picks
    -- up their own, through the game, so its card shows and the quest moves on. Shared, the other player got it quietly in
    -- the bag, their copy of the pickup gone: the quest never knew (the tower key), or they handed in what they never found
    -- (Yuer's flower). Read once from the table.
    game.narrative = nil
    function game.isNarrative(id)
        if type(id) ~= "string" or id == "?" or id == "None" then
            return false
        end
        if game.narrative == nil then
            local set = {}
            pcall(function()
                local path = "/Game/PBZContent/DataTable/Item/DT_InventoryData.DT_InventoryData"
                local t = StaticFindObject(path)
                if not valid(t) and type(LoadAsset) == "function" then
                    LoadAsset(path)
                    t = StaticFindObject(path)
                end
                local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
                if not (valid(t) and valid(lib)) then
                    return
                end
                local function col(name)
                    local out, v = {}, lib:GetDataTableColumnAsString(t, FName(name))
                    for i = 1, #v do
                        local s = v[i]
                        pcall(function() s = s:get() end)
                        pcall(function() s = s:ToString() end)
                        out[i] = tostring(s)
                    end
                    return out
                end
                local ids, kinds, held = col("ItemId"), col("ItemDetailType"), col("AddTagWhenHas")
                local all, flags = {}, {}   -- (every item's kind: game.pickupSharesDue gives only these)
                for i = 1, #ids do
                    all[ids[i]] = kinds[i] or "?"
                    if (kinds[i] or ""):find("Narrative", 1, true) then
                        set[ids[i]] = true
                    end
                    flags[ids[i]] = (held[i] or ""):match('TagName="([^"]+)"')
                end
                game.itemKinds = all
                game.heldFlags = flags  -- (a thing's own flag while it's held: grantLoot)
                game.narrative = set
                log("Quest items in the game's table: " .. tostring(#ids) .. " items read.")
            end)
            if game.narrative == nil then
                return false        -- (asked again next time: the table may not be loaded yet)
            end
        end
        return game.narrative[id] == true
    end

    -- Whether a tag is a thing's own flag while it's held (the table's AddTagWhenHas): its holder's alone, as the thing is.
    -- (flowsync's DB: a guest's own find in the look after a boss's death isn't the boss's win, and on the host a hand-in
    -- that reads the flag took it for the thing held: the review.)
    function game.isHeldFlag(tag)
        if game.heldSet == nil then
            game.isNarrative("-")       -- (the table read, once)
            if game.heldFlags == nil then
                return false
            end
            game.heldSet = {}
            for _, flag in pairs(game.heldFlags) do
                game.heldSet[flag] = true
            end
        end
        return game.heldSet[tag] == true
    end

    -- Quest items are shared now (a player report, 11-06: letters, notes, the Black and Orange Stones, keys "just disappear
    -- for the other player with no notification"). Since flowsync.lua the host's story steps reach everyone, and a quest
    -- item's pickup is often a step of its own: the partner's copy vanished with the step, and nothing given. So a quest
    -- item comes to everyone like any find, with its card. game.shareQuestItems = false is the old rule (each their own).
    game.shareQuestItems = true
    -- (The table read all the same: watchPickups tells a pickup only once it's read, and shared, nothing else read it. No
    -- pickup was told, the partner's copy stayed, and the second to pick it up had two, a Killing Aura Amber say: a report
    -- on 1.6.9, a slip of 1.6.7's.)
    function game.keptApart(id)
        local quest = game.isNarrative(id)
        return not game.shareQuestItems and quest
    end

    -- A dialogue is open: a talk with an NPC (a hand-in too). Story steps, and a partner's scene skip, wait for it.
    function game.inDialogue()
        local open = false
        pcall(function()
            for _, d in ipairs(FindAllOf("WBP_FlowDialog_C") or {}) do
                if valid(d) and d:IsInViewport() and d:IsVisible() then
                    open = true
                end
            end
        end)
        if open then
            game.dialogueAt = os.clock()
        end
        return open or os.clock() - (game.dialogueAt or -1e9) < 5
    end

    -- What the partner's bag has and this one lacks. Returns how many things came. counts false: things that are counted
    -- (used up as they're used) aren't topped up, only what one has or hasn't: after the first merge with a partner, a
    -- sync started again refilled the bombs and herbs used since.
    function game.mergeBag(pawn, entries, counts)
        local bp = valid(pawn) and worldSubsystem(pawn, BACKPACK)
        if not bp then
            return 0
        end
        local have = {}
        for _, e in ipairs(game.bagSummary(pawn)) do
            local kind, id, n = e:match("^(%a):(.+):(%d+)$")
            have[kind .. ":" .. id] = tonumber(n)
        end
        local came = 0
        for _, e in ipairs(entries) do
            local kind, id, n = e:match("^(%a):([%w_%-]+):(%d+)$")
            n = n and math.min(tonumber(n), 9999)
            local key = kind and kind .. ":" .. id
            local mine = key and have[key] or nil
            if kind == "p" and counts ~= false and n and n > (mine or 0) then
                game.grantLoot(pawn, id, nil, n - (mine or 0), true)
                came = came + 1
            elseif kind == "m" and id == "Hulu" and mine == nil then
                -- The healing gourd, which grantLoot never hands over (in the prologue it came unequipped, and none to drink
                -- from): past the prologue, a player without one gets it equipped and full. The game's own prologue skip
                -- (New Game, 66 days) left a guest with none (the user, 11-06), as did joining from the prologue in 1.6.3.
                if not (game.inPrologue and game.inPrologue()) then
                    game.giveGourd(true)
                    came = came + 1
                end
            elseif kind and kind ~= "p" and mine == nil then
                game.grantLoot(pawn, id, ({ w = "weapon", e = "weapon2", a = "accessory", m = "medicine" })[kind], nil, true)
                if gearKnown then
                    gearKnown[id] = true     -- (or the next look at the lists sends it back as found)
                end
                came = came + 1
            end
            if key and n then
                have[key] = math.max(n, mine or 0)  -- (two bags in one go: the most of the two, not both gaps added)
            end
        end
        return came
    end

    -- Each world has its own copy of every chest and rubbish pile, named alike. Its items reach the partner as above, so
    -- their copy only has to stop paying: a chest counts as opened, a pile goes, as a pickup's copy does. One that isn't
    -- loaded there goes as soon as it is. (A chest that's locked until a boss dies stays locked for both.)
    local CHEST_CLASS, PILE_CLASS = "BP_Chest_C", "BP_Rubbish_C"
    local PILE_SEARCHED = "/Game/PBZContent/Blueprint/Item/Device/BP_Rubbish.BP_Rubbish_C:OnInteract"
    local CHEST_WATCH_CM = 2000     -- a chest that opens after being this close to the player: they opened it
    local closedNear, retiring, searched = {}, {}, {}
    local pileHooked = false
    -- The host's open chests (coop.lua, OC): named to the guests again every OFFER_S, for one who joins later, and paid
    -- on a guest PAYS a second at most. And what's needed to show a chest open that opened without its sequence.
    local chests = { OFFER_S = 60, PAYS = 3, offered = {}, offeredAt = -1e9, owed = {},
        OPENING = "/HuaShira/SceneProp/Chest/Anim/Chest_Close2Open.Chest_Close2Open",
        OPENED = "/HuaShira/SceneProp/Chest/Anim/Chest_Open.Chest_Open",
        LID_S = 1.9,                -- Chest_Close2Open is shut until about here, then opens in a second and a half
        MESH = "/Script/Engine.SkeletalMeshComponent",
        LOOT = "/Game/PBZContent/DataTable/DT_LevelLootDataTable.DT_LevelLootDataTable", levelLoot = nil }

    -- Sync stopped: dust earned and things taken alone from now on aren't news for the next partner.
    function game.forgetLink()
        lastDust, syncedDust = nil, 0
        gearKnown = nil
        watched = {}
        closedNear = {}
        chests.offered, chests.owed = {}, {}
    end

    local function chestOpen(chest)
        local ok, open, started = pcall(function() return chest.CurSwitchState, chest.bInteracted end)
        return not ok or open == true or started == true
    end

    -- A chest switched open without its sequence still looks shut: its lid is posed here by the game's own animation
    -- for that mesh (the one the blueprint names is for another skeleton), and its glow and the light that sweeps over
    -- it go, as on the opener's side. In view it swings open; one that loads later is just open.
    function chests.showOpen(chest, swing)
        pcall(function()
            local mesh, kind = chest.Chest, StaticFindObject(chests.MESH)
            local anim = StaticFindObject(swing and chests.OPENING or chests.OPENED)
            if valid(mesh) and valid(kind) and mesh:IsA(kind) and valid(anim)
                and anim.Skeleton:GetFullName() == mesh:GetSkeletalMeshAsset().Skeleton:GetFullName() then
                mesh:SetComponentTickEnabled(true)
                mesh.VisibilityBasedAnimTickOption = 0      -- (left as it is, a shut chest's pose doesn't move)
                mesh:PlayAnimation(anim, false)
                if swing then
                    mesh:SetPosition(chests.LID_S, false)
                end
            end
        end)
        pcall(function()
            local glow = chest.Niagara
            if valid(glow) then
                glow:Deactivate()
                glow:SetVisibility(false, false)
            end
        end)
        pcall(function() chest["Not Swipe"](chest) end)
    end

    function chests.text(v)
        if type(v) == "string" then
            return v
        end
        local ok, s = pcall(function() return v:get():ToString() end)
        if not (ok and s) then
            ok, s = pcall(function() return v:ToString() end)
        end
        return ok and s or ""
    end

    -- What a chest holds, from the game's table of what's placed in the world: { dust, { id, count, kind }... }, or nil.
    -- Read as text, once, as the game's own table tools do: its own roll can't be called from here (that took the game down).
    -- (First play-through amounts: the table's dust for later ones is a multiple this doesn't know.)
    function chests.loot(chest)
        local text = chests.text
        if chests.levelLoot == nil then
            local lib, t = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary"), StaticFindObject(chests.LOOT)
            if not (valid(lib) and valid(t)) then
                return nil
            end
            local names = {}
            lib:GetDataTableRowNames(t, names)
            local entries = lib:GetDataTableColumnAsString(t, FName("EntryDatas"))
            chests.levelLoot = {}
            for i = 1, #names do
                chests.levelLoot[text(names[i])] = text(entries[i])
            end
        end
        local entry = chests.levelLoot[text(chest["Loot Item ID"])]
        if not entry then
            return nil
        end
        local function rolled(p)
            return math.random() <= (tonumber(p) or 1)
        end
        local function amount(lo, hi)
            lo, hi = math.floor(tonumber(lo) or 1), math.floor(tonumber(hi) or tonumber(lo) or 1)
            return hi > lo and math.random(lo, hi) or lo
        end
        local loot = { dust = 0 }
        for lo, hi, times, p in (entry:match("LootDusts=(%b())") or ""):gmatch("MinDust=(%d+),MaxDust=(%d+),CycleDustMultipliers=%(([%d.]+)[^)]*%),Probability=([%d.]+)") do
            if rolled(p) then
                loot.dust = loot.dust + math.floor(amount(lo, hi) * (tonumber(times) or 1) + 0.5)
            end
        end
        for id, lo, hi, p in entry:gmatch('ItemId="([^"]+)",MinAmount=(%d+),MaxAmount=(%d+),Probability=([%d.]+)') do
            if rolled(p) then
                loot[#loot + 1] = { id = id, count = amount(lo, hi) }
            end
        end
        for id, main, p in entry:gmatch('WeaponID="([^"]+)",IsMainWeapon=(%a+),Probability=([%d.]+)') do
            if rolled(p) then
                loot[#loot + 1] = { id = id, count = 1, kind = main == "True" and "weapon" or "weapon2" }
            end
        end
        for id, p in entry:gmatch('MedicineID="([^"]+)",.-Probability=([%d.]+)') do
            if rolled(p) then
                loot[#loot + 1] = { id = id, count = 1, kind = "medicine" }
            end
        end
        for id, p in entry:gmatch('AccessoryID="([^"]+)",Probability=([%d.]+)') do
            if rolled(p) then
                loot[#loot + 1] = { id = id, count = 1, kind = "accessory" }
            end
        end
        return loot
    end

    -- A chest the host has open and this player's world still has shut: it pays them, then shows open. False, and left
    -- as it is, while the game's table isn't there to say what it holds.
    function chests.pay(chest, name, pawn)
        local ok, loot = pcall(chests.loot, chest)
        if not ok or chests.levelLoot == nil then
            return false
        end
        for _, item in ipairs(loot or {}) do
            game.grantLoot(pawn, item.id, item.kind, item.count)
        end
        if loot then
            game.addCurrency(pawn, loot.dust)
        end
        pcall(function() chest:SwitchWithoutPlaySequence() end)
        chests.showOpen(chest, false)
        if api.flowsync and api.flowsync.raise then
            api.flowsync.raise(game.successTags(chest), name)     -- (what its own opening raises: game.successTags)
        end
        log("The host's " .. name .. " is open: " .. (loot and (#loot .. " things and " .. loot.dust .. " dust from it here too.")
            or "it isn't in the game's table, so nothing to pay."))
        return true
    end

    -- Guest: a chest the host has open (OC). It pays when it's next seen shut here (watchChests).
    function game.hostOpened(name)
        chests.owed[name] = true
    end

    -- The address of what this player is opening right now, if anything. (Not the chest's InteractPlayer: that's whoever
    -- stands by it.)
    function chests.opening(pawn)
        local ok, addr = pcall(function()
            local thing = pawn:GetComponentByClass(StaticFindObject("/Script/ProjectPBZ.PBZInteractComponent")):GetInteractingActor()
            return valid(thing) and thing:GetAddress() or nil
        end)
        return ok and addr or nil
    end

    -- Host: someone (re)joined. The open chests here are named again at the next look.
    function game.offerChestsAgain()
        chests.offeredAt = -1e9
    end

    -- A kick-stone, a boulder that shuts a shortcut until it's kicked away, is each world's own, and a copy can't be kicked
    -- from here: the kick is the kicker's own animation (its physics and finishing steps alone leave it where it stands), so
    -- the partner's stood in the way ("the guest opened a gate, it did not open for host"). The kicker's world says where its
    -- boulder came to rest (coop.lua, KS), and the partner's is switched open and put there; one not loaded yet, when it is.
    chests.STONE, chests.STONE_REST_S = "BP_KickStone_C", 4.0
    chests.stones = { shut = {}, settling = {}, pending = {} }

    function chests.placeStone(stone, at, rot)
        pcall(function()
            if stone.CurSwitchState ~= true then
                stone:SwitchWithoutPlaySequence()
            end
            stone.SkeletalMesh:K2_SetWorldLocationAndRotation(at, rot, false, {}, true)
        end)
    end

    -- Once a second: a stone that was shut near this player and is open now, they kicked; told once it has come to rest.
    function game.watchStones(pawn, report)
        local here, st, shut = pawn:K2_GetActorLocation(), chests.stones, {}
        for _, s in ipairs(FindAllOf(chests.STONE) or {}) do
            if valid(s) then
                local name = s:GetFName():ToString()
                local open = s.CurSwitchState == true
                if st.pending[name] then
                    chests.placeStone(s, st.pending[name].at, st.pending[name].rot)
                    st.pending[name] = nil
                elseif open and st.shut[name] then
                    st.settling[name] = os.clock() + chests.STONE_REST_S
                elseif not open and distance(s:K2_GetActorLocation(), here) <= CHEST_WATCH_CM then
                    shut[name] = true
                end
                if open and st.settling[name] and os.clock() >= st.settling[name] then
                    st.settling[name] = nil
                    pcall(function()
                        local m = s.SkeletalMesh
                        report(name, m:K2_GetComponentLocation(), m:K2_GetComponentRotation())
                    end)
                end
            end
        end
        st.shut = shut
    end

    function game.stoneKicked(name, at, rot)
        chests.stones.shut[name], chests.stones.settling[name] = nil, nil     -- (not this player's kick: not told back)
        for _, s in ipairs(FindAllOf(chests.STONE) or {}) do
            if valid(s) and s:GetFName():ToString() == name then
                chests.placeStone(s, at, rot)
                return
            end
        end
        chests.stones.pending[name] = { at = at, rot = rot }
    end

    -- The flags a pile or chest's own flow raises once it's searched: its flow presets' AddTagWhenSuccess (one of Yuer's
    -- herbs, "xg.营地玉儿.药材1"). A partner's search took our copy away and sent its things (O, T), but never these, and a
    -- quest counting them stayed short here: two herbs found by the partner, the map saying all three were in, and Yuer not
    -- taking them (a player report on 1.7.1). They go with the word now (coop.lua's OF). As text, read at once.
    function game.successTags(a)
        local tags = {}
        if not valid(a) then
            return tags
        end
        pcall(function()
            local list = a.BP_PBZFlowComponent.FlowPresetDataList
            for i = 1, #list do
                local p = list[i]
                pcall(function() p = p:get() or p end)
                if valid(p) then
                    pcall(function()
                        p.AddTagWhenSuccess.GameplayTags:ForEach(function(_, t)
                            local s = t:get().TagName:ToString()
                            if s ~= "" and s ~= "None" then
                                tags[#tags + 1] = s
                            end
                        end)
                    end)
                end
            end
        end)
        return tags
    end

    -- A pile says nothing once searched, so its own step is what's watched.
    function game.hookPiles(report)
        if pileHooked or not valid(StaticFindObject(PILE_SEARCHED)) then
            return
        end
        pileHooked = true
        pcall(function()
            RegisterHook(PILE_SEARCHED, function(self)
                local ok, name = pcall(function() return self:get():GetFName():ToString() end)
                if ok and not searched[name] then
                    searched[name] = true
                    local _, pile = pcall(function() return self:get() end)
                    report(name, game.successTags(pile))
                end
            end)
        end)
    end

    -- Once a second: a chest that was near this player and closed, and now isn't, they opened. offer (the host's): each
    -- chest open here is named to the guests, once a while.
    function game.watchChests(pawn, report, offer)
        local here = pawn:K2_GetActorLocation()
        local closed = {}
        local pays, offered, owed = chests.PAYS, chests.offered, chests.owed
        if offer and os.clock() - chests.offeredAt >= chests.OFFER_S then
            offered = {}
            chests.offered, chests.offeredAt = offered, os.clock()
        end
        local busy = next(owed) ~= nil and chests.opening(pawn) or nil
        for _, c in ipairs(FindAllOf(CHEST_CLASS) or {}) do
            if valid(c) then
                local name = c:GetFName():ToString()
                if chestOpen(c) then
                    retiring[name], owed[name] = nil, nil
                    if closedNear[name] then
                        offered[name] = true    -- (opened just now: its things go by what the game gives)
                        report(name, game.successTags(c))
                    elseif offer and not offered[name] then
                        offered[name] = true
                        offer(name)
                    end
                elseif retiring[name] then
                    retiring[name] = nil
                    if not game.holdsQuestItem(c) then
                        pcall(function() c:SwitchWithoutPlaySequence() end)
                        chests.showOpen(c, false)
                    end
                else
                    local paid = false
                    if owed[name] and pays > 0 and c:GetAddress() ~= busy then    -- (not one they're opening)
                        pays = pays - 1
                        paid = chests.pay(c, name, pawn)
                        if paid then
                            owed[name] = nil
                        end
                    end
                    if not paid and (closedNear[name] or distance(c:K2_GetActorLocation(), here) <= CHEST_WATCH_CM) then
                        closed[name] = true     -- (Near once is enough: the player can walk off while it opens.)
                    end
                end
            end
        end
        closedNear = closed
        if next(retiring) then
            for _, p in ipairs(FindAllOf(PILE_CLASS) or {}) do
                if valid(p) and retiring[p:GetFName():ToString()] then
                    retiring[p:GetFName():ToString()] = nil
                    if not game.holdsQuestItem(p) then
                        pcall(function() p:K2_DestroyActor() end)
                    end
                end
            end
        end
    end

    -- A pile or chest whose content is a quest item ("<map>.K_03001": a key, the Snake Tongue, a token half). Opened by a
    -- partner, it stays here for this player to open: taken away, the quest item went with it, never shared (quest items
    -- aren't), and the quest was stuck until they swapped host and guest (issue #15).
    function game.holdsQuestItem(c)
        local id = nil
        pcall(function() id = c["Loot Item ID"]:ToString() end)
        if type(id) ~= "string" or id == "None" then
            pcall(function() id = c["Item ID"]:ToString() end)
        end
        local item = type(id) == "string" and id:match("([^%.]+)$") or nil
        return item ~= nil and item ~= "None" and game.keptApart(item), item
    end

    function game.partnerOpened(name)
        local isPile = name:find("^BP_Rubbish") ~= nil
        closedNear[name] = nil
        for _, c in ipairs(FindAllOf(isPile and PILE_CLASS or CHEST_CLASS) or {}) do
            if valid(c) and c:GetFName():ToString() == name then
                local quest, item = game.holdsQuestItem(c)
                if quest then
                    log("The other player opened " .. name .. ": it holds a quest item (" .. tostring(item) .. "), left here for you.")
                    return
                end
                if isPile then
                    pcall(function() c:K2_DestroyActor() end)
                elseif not chestOpen(c) then
                    pcall(function() c:SwitchWithoutPlaySequence() end)
                    chests.showOpen(c, true)
                end
                return
            end
        end
        retiring[name] = true
    end

    -- How many of this item the backpack holds (0 if it has no entry).
    function game.itemCount(bp, itemId)
        local n = 0
        pcall(function()
            bp.Inventories:ForEach(function(k, v)
                if k:get():ToString() == itemId then
                    n = v:get().CurrentAmount
                end
            end)
        end)
        return n
    end

    -- Short name of the current map, so a ghost from another map isn't shown in this one.
    -- In a cutscene: the game's own level-sequence manager. The manager is looked up again only every 2 s while
    -- it isn't found (this runs with every snapshot). (From appdoze's PR #5.)
    local seqManager, seqLookupAt = nil, -1e9
    local seqOrphanSince = nil      -- since when the manager says "in sequence" with nothing playing
    local SEQ_ORPHAN_S = 8.0

    -- The player of this world's scene. A story scene the game's flow starts (a boss's change of phase, its end) plays
    -- through a sequence actor of its own: the manager only knows one is on, and which, with no session player. The actor
    -- playing the manager's scene is looked for at most once a second while none is known.
    local sceneActor, sceneLookAt = nil, -1e9
    local function playing(p)
        local ok, on = pcall(function() return valid(p) and p:IsPlaying() end)
        return ok and on == true
    end
    local function sceneOf(p)
        local name = nil
        pcall(function()
            local s = p:GetSequence()
            if valid(s) then
                name = s:GetFName():ToString()
            end
        end)
        return name
    end
    local function scenePlayer()
        local session = nil
        pcall(function() session = seqManager.ActiveSessionPlayer end)
        if valid(session) then
            return session
        end
        if valid(sceneActor) and playing(sceneActor.SequencePlayer) then
            return sceneActor.SequencePlayer
        end
        sceneActor = nil
        local now = os.clock()
        if now - sceneLookAt < 1.0 then
            return nil
        end
        sceneLookAt = now
        local current = nil
        pcall(function()
            local s = seqManager:GetCurrentSequence()
            if valid(s) then
                current = s:GetFName():ToString()
            end
        end)
        if current == nil then
            return nil
        end
        for _, a in ipairs(FindAllOf("LevelSequenceActor") or {}) do
            local p = valid(a) and a.SequencePlayer
            if p and playing(p) and sceneOf(p) == current then
                sceneActor = a
                return p
            end
        end
        return nil
    end

    -- A scene playing: the game's sequence manager says one is, and it has the camera. A sequence with the camera still on
    -- the player is no scene to the player: seen in Bai Chilian's arena, where one ran on for a minute of fighting, and a
    -- guest taken for "in a scene" had their figure hidden on the host and off every enemy's list, so the boss stood still.
    function game.inCutscene()
        if not game.sequenceOn() then
            return false
        end
        local onPlayer = false
        pcall(function()
            local pc, pawn = api.getPlayer1()
            if valid(pc) and valid(pawn) then
                local vt = pc:GetViewTarget()
                -- (This mod's spectating camera is the player's own view, not a scene: a dead player watching in such an
                -- arena read as in one, their partner's figure hidden and the camera jumping every few seconds.)
                onPlayer = valid(vt) and (vt:GetAddress() == pawn:GetAddress()
                    or (valid(spectateCam) and vt:GetAddress() == spectateCam:GetAddress()))
            end
        end)
        return not onPlayer
    end

    function game.sequenceOn()
        if not valid(seqManager) then
            local now = os.clock()
            if now - seqLookupAt < 2.0 then
                return false
            end
            seqLookupAt = now
            seqManager = FindFirstOf("PBZLevelSequenceManager")
            if not valid(seqManager) then
                return false
            end
        end
        local ok, playing = pcall(function() return seqManager:IsInSequence() end)
        if not (ok and playing == true) then
            seqOrphanSince = nil
            return false
        end
        -- A sequence that lost its player (seen once, after a sequence started by hand) leaves the flag up for
        -- good. Without a player or a session for SEQ_ORPHAN_S, it doesn't count as a scene any more.
        local okP, hasPlayer = pcall(function()
            return valid(seqManager.ActiveSessionPlayer) or valid(seqManager.ActiveSessionProxy)
        end)
        if okP and hasPlayer then
            seqOrphanSince = nil
            return true
        end
        if scenePlayer() then
            seqOrphanSince = nil            -- (a scene of the flow's: on for as long as it plays, past SEQ_ORPHAN_S too)
            return true
        end
        seqOrphanSince = seqOrphanSince or os.clock()
        return os.clock() - seqOrphanSince < SEQ_ORPHAN_S
    end

    -- The scene this world is playing, by its sequence's name, or nil. (The manager hands back nothing between scenes:
    -- a name asked of nothing is a crash in UE4SS, so it's looked at first.)
    function game.sceneName()
        if not game.inCutscene() then
            return nil
        end
        local name = nil
        pcall(function()
            local s = seqManager:GetCurrentSequence()
            if valid(s) then
                name = s:GetFName():ToString()
            end
        end)
        return name
    end

    -- How long this world's scene runs at its own speed, in seconds, or nil.
    function game.sceneLength()
        local length = nil
        pcall(function()
            local p = game.inCutscene() and scenePlayer()
            if p then
                local frames, rate = p:GetFrameDuration(), p:GetFrameRate()
                local fps = rate.Numerator / rate.Denominator
                if frames > 0 and fps > 0 then
                    length = frames / fps
                end
            end
        end)
        return length
    end

    -- This world's scene, ended where it would end by itself, as a skip does: what follows it runs.
    function game.skipScene()
        local ok = false
        pcall(function()
            local p = game.inCutscene() and scenePlayer()
            if p then
                p:GoToEndAndStop()
                ok = true
            end
        end)
        return ok
    end

    function game.mapName(contextActor)
        local ok, name = pcall(function() return api.gs():GetCurrentLevelName(contextActor, true):ToString() end)
        return ok and name or "?"
    end

    -- The prologue (ZhuLinGuWu, the bamboo grove of a new game): its own stripped loadout, and the starting gear, the healing
    -- gourd among it, handed out as it ends. Co-op keeps its hands off there (a new game's players both lost the gourd).
    game.prologueAt, game.prologueSeen = -1e9, false
    function game.inPrologue()
        local now = os.clock()
        if now - game.prologueAt >= 2 then
            game.prologueAt = now
            local _, pawn = api.getPlayer1()
            local name = valid(pawn) and game.mapName(pawn) or "?"
            game.prologueSeen = name:find("ZhuLinGuWu", 1, true) ~= nil or name:find("ZLGW", 1, true) ~= nil
        end
        return game.prologueSeen
    end

    -- A level the game's own map table lists: a name from the network is never loaded on its word alone.
    local MAP_TABLE = "/Game/PBZContent/DataTable/UI/DT_MapData.DT_MapData"
    local storyLevels = nil
    function game.isStoryLevel(level)
        if storyLevels == nil then
            local t = StaticFindObject(MAP_TABLE)
            local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
            if not (valid(t) and valid(lib)) then
                return false
            end
            local names = lib:GetDataTableColumnAsString(t, FName("LevelName"))
            storyLevels = {}
            for i = 1, #names do
                storyLevels[names[i]:get():ToString()] = true
            end
        end
        return storyLevels[level] == true and level ~= "None" and level ~= "Rhm_Test"
    end

    -- To a spot on any story map, the way a bell does it: the game saves, then loads there.
    function game.travel(level, at)
        local save = FindFirstOf("PBZSaveLoadSubsystem")
        if not (valid(save) and game.isStoryLevel(level)) then
            return false
        end
        return (pcall(function()
            save:TeleportTo(FName(level), { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                Translation = { X = at.X, Y = at.Y, Z = at.Z + 100 }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }, FName(""))
        end))
    end

    ------------------------------------------------------------------ test helpers (commands)

    local function spawnAt(cls, loc, yaw)
        local gs = api.gs()
        local pc = api.getPlayer1()
        local t = {
            Rotation = { X = 0.0, Y = 0.0, Z = math.sin(math.rad(yaw) / 2), W = math.cos(math.rad(yaw) / 2) },
            Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        local actor = gs:BeginDeferredActorSpawnFromClass(pc, cls, t, SPAWN_ADJUST_ALWAYS, nil, SCALE_MULTIPLY_WITH_ROOT)
        if not valid(actor) then
            return nil
        end
        actor = gs:FinishSpawningActor(actor, t, SCALE_MULTIPLY_WITH_ROOT)
        if valid(actor) then
            actor:K2_SetActorLocationAndRotation(t.Translation, { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false, {}, true)
        end
        return actor
    end

    -- unlockall: every weapon and Phantom Edge weapon into the backpack, for testing moves and skills (PvP).
    -- Weapon ids are the folder names under the player's ability assets (WoodenSword, IronBlade, ...; Phantom
    -- Edge ones under ShachiAbility), read from the asset registry. Changes the save: test saves only.
    game.commands.unlockall = function()
        local _, pawn = api.getPlayer1()
        local bp = lib("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(pawn,
            StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem"))
        local ar = lib("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAssetRegistry()
        local root = "/PBZCombatAsset/ActorData/Players/Hun/Abilities"
        local notWeapons = { BreakEscape = true, Common = true, GameplayBlocker = true, HorseCart = true,
            Passive = true, ShachiAbility = true, SpecialMove = true, Tutorial = true, Unarm = true }
        local function folders(path)
            local paths, out = {}, {}
            ar:GetSubPaths(path, paths, false)
            for _, v in ipairs(paths) do
                local s = v:get()
                s = (type(s) == "string" and s or s:ToString()):match("([^/]+)$")
                out[#out + 1] = s
            end
            return out
        end
        for _, id in ipairs(folders(root)) do
            if not notWeapons[id] and not id:find("^Temp_") then
                pcall(function() bp:AddWeaponItem(FName(id), true, false, false, false) end)
            end
        end
        for _, id in ipairs(folders(root .. "/ShachiAbility")) do
            pcall(function() bp:AddWeaponItem(FName(id), false, false, false, false) end)
        end
        local main, edge = 0, 0
        bp.MainWeaponInfos:ForEach(function() main = main + 1 end)
        bp.ShaqiWeaponInfos:ForEach(function() edge = edge + 1 end)
        log(string.format("Unlocked: %d weapons, %d Phantom Edge weapons.", main, edge))
    end

    -- spawnenemy <codex row> [distance cm]: spawn one of the game's enemies in front of player 1.
    game.commands.spawnenemy = function(args)
        local name, dist = (args or ""):match("^(%S+)%s*(%d*)")
        if not name then
            log("Usage: spawnenemy <codex row, e.g. BP_Monster_MaleThug_Sword_Blue> [distance]")
            return
        end
        local row = codexRow(name)
        if row == nil then
            log("No codex row " .. name)
            return
        end
        local ksl = lib("/Script/Engine.Default__KismetSystemLibrary")
        local cls = ksl:LoadClassAsset_Blocking(row.EnemyClass)
        if not valid(cls) then
            log("Couldn't load class for " .. name)
            return
        end
        local _, pawn = api.getPlayer1()
        local l = pawn:K2_GetActorLocation()
        local yaw = pawn:K2_GetActorRotation().Yaw
        local d = tonumber(dist) or 700
        local at = { X = l.X + math.cos(math.rad(yaw)) * d, Y = l.Y + math.sin(math.rad(yaw)) * d, Z = l.Z + 30 }
        local e = spawnAt(cls, at, yaw + 180)
        if not valid(e) then
            log("Spawn failed for " .. name)
            return
        end
        pcall(function() e:SpawnDefaultController() end)
        local hp, maxhp = game.getHealth(e)
        log(string.format("Spawned %s (%s) hp=%s/%s boss=%s", e:GetFName():ToString(), name, tostring(hp),
            tostring(maxhp), tostring(row.bIsBoss)))
    end

    -- codex [bosses]: list enemy codex rows (or only the bosses).
    game.commands.codex = function(args)
        local dt = lib(CODEX_TABLE)
        local onlyBosses = args == "bosses"
        local names = {}
        dt:ForEachRow(function(rowName, row)
            local n = type(rowName) == "string" and rowName or tostring(rowName:ToString())
            if not onlyBosses or row.bIsBoss then
                names[#names + 1] = n
            end
        end)
        log((onlyBosses and "Boss rows: " or "Enemy rows: ") .. #names)
        for i = 1, #names, 8 do
            log("  " .. table.concat(names, " ", i, math.min(#names, i + 7)))
        end
    end

    -- enemies: every enemy the mod sees, with health and boss flag.
    game.commands.enemies = function()
        local _, pawn = api.getPlayer1()
        local here = valid(pawn) and pawn:K2_GetActorLocation() or nil
        local list = game.listEnemies()
        log("Enemies: " .. #list)
        for _, e in ipairs(list) do
            local hp, maxhp = game.getHealth(e)
            local d = here and distance(e:K2_GetActorLocation(), here) or -1
            log(string.format("  %s hp=%s/%s dead=%s boss=%s %.0f cm", e:GetFName():ToString(), tostring(hp),
                tostring(maxhp), tostring(game.isDead(e)), tostring(game.isBoss(e)), d))
        end
    end

    -- items: pickups near player 1.
    game.commands.items = function()
        local _, pawn = api.getPlayer1()
        local here = pawn:K2_GetActorLocation()
        local all = FindAllOf("PBZPickupActor") or {}
        log("Pickups loaded: " .. #all)
        for _, p in ipairs(all) do
            if valid(p) then
                local d = distance(p:K2_GetActorLocation(), here)
                if d < 5000 then
                    log(string.format("  %s item=%s %.0f cm", p:GetFName():ToString(), pickupItemId(p), d))
                end
            end
        end
    end

    return game
end
