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

    local function holdGhost(ghost)
        if api.coop and api.coop.net.party then
            busyGhosts[ghost:GetAddress()] = os.clock() + GHOST_BUSY_S
        else
            ghostBusyUntil = os.clock() + GHOST_BUSY_S
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

    -- addr: the actor's address, when the caller has it.
    function game.enemyId(actor, addr)
        addr = addr or actor:GetAddress()
        local id = spawnerIds[addr]
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
    function game.stopAI(actor, brain)
        pcall(function()
            if not valid(brain) then
                brain = actor:GetController().BrainComponent
            end
            if brain:IsRunning() then
                brain:StopLogic("PhantomPact")
            end
        end)
        return brain
    end

    function game.startAI(actor)
        pcall(function() actor:GetController().BrainComponent:RestartLogic() end)
    end

    -- Out of the way on this PC, and back: coop.lua, for an enemy the host's world doesn't have.
    function game.stepAside(actor, on)
        pcall(function()
            actor:SetActorHiddenInGame(on)
            actor:SetActorEnableCollision(not on)
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

    -- The other player's boss, on this PC too: a boss only spawns on the PC whose player started the fight. Returns
    -- its spawner's location, or nil for an enemy that doesn't come from a named spawner.
    function game.spawnBoss(enemyId)
        local id = enemyId:match("^sp:(.+)$")
        for _, s in ipairs(id and FindAllOf("AISpawner") or {}) do
            local sid = nil
            pcall(function() sid = s.SpawnerID:ToString() end)
            -- (A spawner with no designer id goes by its level name: see readSpawner.)
            if sid == id or (sid == "None" and s:GetFName():ToString() == id) then
                local at = s:K2_GetActorLocation()
                local alive = false
                pcall(function() alive = valid(s.SpawnedAI) and not game.isDead(s.SpawnedAI) end)
                if not alive then
                    local ok, err = pcall(function() s:ClaimSeqSpawn(false, true, true) end)
                    if not ok then
                        log("Couldn't spawn " .. id .. ": " .. tostring(err))
                    end
                end
                return { X = at.X, Y = at.Y, Z = at.Z }
            end
        end
        return nil
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
        if bosses[actor:GetAddress()] then
            pcall(function()
                local addr = actor:GetAddress()
                local hud = FindFirstOf("PBZHUDLayout")
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

    -- The bosses of the fights going on: live actors only.
    function game.bossActors()
        local out = {}
        for addr, actor in pairs(bossActors) do
            if bosses[addr] and valid(actor) and not game.isDead(actor) then
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
            local ai = actor.Mesh:GetAnimInstance()
            local m = ai:GetCurrentActiveMontage()
            if valid(m) then
                ai:Montage_Stop(0.1, m)
            end
        end)
    end

    function game.kill(actor)
        local boss = game.isBoss and game.isBoss(actor)
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
    end

    -- The player's own death, the game's normal flow (screen, respawn, refresh): the game's own kill effect. A player has
    -- no Kill, and health set to 0 by hand only leaves them lying there with no way back.
    local KILL_EFFECT = "/Game/PBZContent/Blueprint/Ability/GameplayEffects/GE_Kill"
    function game.killPlayer(pawn)
        game.setMinHealth(pawn, 0)
        local ok, err = pcall(function()
            local effect = StaticFindObject(KILL_EFFECT .. ".GE_Kill_C")
            if not valid(effect) then
                LoadAsset(KILL_EFFECT)
                effect = StaticFindObject(KILL_EFFECT .. ".GE_Kill_C")
            end
            StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
                :GetAbilitySystemComponent(pawn):BP_ApplyGameplayEffectToSelf(effect, 1.0, {})
        end)
        if not ok then
            log("Kill failed: " .. tostring(err))
        end
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

    function game.setPosture(actor, value)
        syncing = true
        pcall(function()
            local s = actor.AttributeSetBase.Shachi
            s.BaseValue = value
            s.CurrentValue = value
        end)
        syncing = false
    end

    -- Host: the client's player hit this enemy. Lower its health and posture; at zero health, let the game run
    -- its death.
    function game.applyDamage(actor, amount, postureDamage)
        local hp = game.getHealth(actor)
        if hp == nil or hp <= 0 then
            return
        end
        local posture = game.getPosture(actor)
        if posture and postureDamage and postureDamage > 0 then
            game.setPosture(actor, math.max(0, posture - postureDamage))
        end
        local left = math.max(0, hp - amount)
        game.setHealth(actor, left)
        if left <= 0 then
            forgetBoss(actor)
            stopSwing(actor)
            syncing = true
            pcall(function() actor:Kill(DIE_DAMAGED) end)
            syncing = false
        end
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
    -- (GiveItem answers without complaint and adds neither of the last two.)
    function game.grantLoot(pawn, itemId, kind, count)
        count = count or 1
        local bp = valid(pawn) and worldSubsystem(pawn, "/Script/ProjectPBZ.PBZBackPackSubsystem")
        if not bp then
            return
        end
        game.granting = true        -- (what the mod adds isn't sent back: see "what the game gives")
        if kind == "weapon" or kind == "weapon2" then
            pcall(function() bp:AddWeaponItem(FName(itemId), kind == "weapon", true, false, false) end)
            log("Shared loot: weapon " .. itemId)
        elseif kind == "medicine" then
            pcall(function() bp:PushMedicineToInventory(FName(itemId), false, true) end)
            log("Shared loot: medicine " .. itemId)
        elseif kind == "accessory" then
            pcall(function() bp:PushAccessoryToInventory(FName(itemId), false) end)
            log("Shared loot: accessory " .. itemId)
        else
            -- AddPropsToBackPack is the backpack's own entry point; if the item count didn't move (seen in the
            -- prologue map, which keeps its own restricted backpack), fall back to the player's GiveItem.
            -- (Notes and keys, R_ and I_, aren't counted in the backpack: no second try for those.)
            local before = game.itemCount(bp, itemId)
            pcall(function() bp:AddPropsToBackPack(count, FName(itemId), true) end)
            local after = game.itemCount(bp, itemId)
            if after <= before and not itemId:find("^[RI]_%d") then
                pcall(function() pawn:GiveItem(FName(itemId), count) end)
                after = game.itemCount(bp, itemId)
            end
            log(string.format("Shared loot: %s x%d (%d -> %d)", itemId, count, before, after))
        end
        game.granting = false
    end

    game.commands.lootlevel = function(arg)
        game.lootLevelOverride = tonumber(arg)
        log("Loot level override: " .. tostring(game.lootLevelOverride) .. " (empty = the enemy's own level)")
    end

    function game.isBoss(actor, addr)
        addr = addr or actor:GetAddress()
        if bosses[addr] then
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

    -- The HUD registers a boss health bar when a boss fight starts: the surest way to know who the boss is.
    local showingRemoteBoss = false
    pcall(function()
        RegisterHook("/Script/ProjectPBZ.PBZHUDLayout:RegisterBossHPBar", function(_, bossParam)
            local boss = bossParam:get()
            if valid(boss) and not bosses[boss:GetAddress()] then
                bosses[boss:GetAddress()] = true
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
                bosses[addr] = nil
                bossActors[addr] = nil
            end
        end)
    end)

    -- The other player's game started a fight with this boss: show its health bar here too (our copy of the
    -- boss mirrors the host's health, so the bar follows the real fight).
    function game.showBossBar(boss)
        if not valid(boss) or bosses[boss:GetAddress()] then
            return
        end
        local hud = FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            log("No HUD layout to show the boss bar on.")
            return
        end
        showingRemoteBoss = true
        local ok, err = pcall(function() hud:RegisterBossHPBar(boss) end)
        showingRemoteBoss = false
        bosses[boss:GetAddress()] = true
        bossActors[boss:GetAddress()] = boss
        log(ok and ("Showing boss bar for " .. boss:GetFName():ToString()) or ("Boss bar failed: " .. tostring(err)))
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
    function game.setBossFog(at, closed)
        local n = 0
        for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            local ok, loc = pcall(function() return door:K2_GetActorLocation() end)
            if ok and loc.X and distance(loc, at) <= FOG_RADIUS_CM then
                local fn = closed and "Close By Mob Script" or "OpenByMobScript"
                if pcall(function() door[fn](door) end) then
                    n = n + 1
                end
            end
        end
        if n > 0 then
            log(string.format("%s %d fog wall(s) at %.0f %.0f.", closed and "Closed" or "Opened", n, at.X, at.Y))
        end
        return n
    end

    -- Is this spot on the far side of the arena's fog wall? The walls stand at its edge, so the nearest one tells.
    function game.outsideFog(spot, at)
        local door, best = nil, 1e12
        for _, d in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            local ok, loc = pcall(function() return d:K2_GetActorLocation() end)
            if ok and loc.X and distance(loc, at) <= FOG_RADIUS_CM and distance(loc, spot) < best then
                door, best = loc, distance(loc, spot)
            end
        end
        return door ~= nil and (spot.X - door.X) * (at.X - door.X) + (spot.Y - door.Y) * (at.Y - door.Y) < 0
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
    -- the move's own motion plays, and count it for the hit attribution above.
    function game.noteGhostMove(ghost)
        holdGhost(ghost)
        ghostMoveAt = os.clock()
    end

    -- Called every snapshot: any GA_* ability that just became active on the local player is sent as a move.
    -- The local player started something (a montage, moves.lua): counts for the hit attribution above.
    function game.noteLocalMove()
        localMoveAt = os.clock()
    end

    function game.watchLocalPlayer(pawn, sendEvent)
        local asc = abilitySystem(pawn)
        if not asc then
            return
        end
        local nowActive = {}
        forEachSpec(asc, function(spec)
            local ability = spec.Ability
            if spec.ActiveCount > 0 and valid(ability) then
                local cls = ability:GetClass()
                local name = cls:GetFName():ToString()
                -- Only Hun's own moves (GA_Hun_Young_A, ..._AdvancedDash, ...); background abilities such as
                -- GA_LocomotionDriver_3DDefault are always active and aren't moves.
                if name:find("^GA_Hun") then
                    local path = cls:GetFullName():gsub("^%S+ ", "")
                    nowActive[path] = true
                    if not activeLocal[path] then
                        -- The facing at the start of the move, so the ghost swings where the player aimed.
                        sendEvent("M", path, string.format("%.1f", pawn:K2_GetActorRotation().Yaw))
                        localMoveAt = os.clock()
                    end
                end
            end
        end)
        activeLocal = nowActive
    end

    -- Replays the remote player's move on the ghost. Gives the ability first if the ghost lacks it.
    local loadTried = {}          -- class path -> true once we tried loading it (a failed load isn't retried)
    function game.playMove(ghost, classPath, yaw)
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
        local asc = abilitySystem(ghost)
        if not asc then
            return
        end
        if yaw then
            pcall(function() ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false) end)
            game.lastMoveYaw = yaw
        end
        local ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
        if not (ok and activated) then
            pcall(function() asc:K2_GiveAbility(cls, 1, -1) end)
            ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
        end
        ghostBusyUntil = os.clock() + GHOST_BUSY_S
        ghostMoveAt = os.clock()
        if not (ok and activated) then
            log("Ghost couldn't play " .. classPath:match("([^.]+)$"))
        end
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
    function game.playAbility(actor, classPath)
        if not classPath:match("^/[%w_/%-]+%.[%w_%-]+$") or #classPath > 256 then
            return false
        end
        local asc = abilitySystem(actor)
        local cls = StaticFindObject(classPath)
        if not (asc and valid(cls)) then
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
        for _, c in ipairs(FindAllOf("HitreactComponent") or {}) do
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == addr then
                hitreactMissUntil[addr] = nil
                return c
            end
        end
        hitreactMissUntil[addr] = os.clock() + HITREACT_RETRY_S
        return nil
    end

    local localHitComp, lastHitState = nil, "None"

    -- Called every snapshot: when the local player starts reacting to a hit (stagger, knockdown...), send the
    -- hit state's tag so the other player's ghost of us reacts the same way.
    function game.watchHitState(pawn, sendEvent)
        if not valid(localHitComp) then
            localHitComp = hitreactComponent(pawn)
            if not localHitComp then
                return
            end
        end
        local ok, tag = pcall(function() return localHitComp:GetCurrentHitState().TagName:ToString() end)
        if not ok then
            return
        end
        if tag ~= lastHitState and tag ~= "None" then
            sendEvent("H", tag)
        end
        lastHitState = tag
    end

    local clearHitStateLater      -- defined below with staggerSelf
    local ghostHitComps = {}      -- ghost address -> its component: a search of them all, so never once per hit
    function game.playHitReaction(ghost, tag)
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
                clearHitStateLater(ghostHitComp, tag)
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
                    local ok, err = pcall(t.fn)
                    if not ok then
                        log("Timer error: " .. tostring(err))
                    end
                end
                return false
            end)
        end
    end

    -- A hit state set by hand has no animation to end it, and while it lasts the character can't start a move
    -- (a PvP attacker stayed stuck after a parry). Clear it again after a moment, unless something replaced it.
    local HIT_STATE_HOLD_S = 0.9
    clearHitStateLater = function(comp, tag)
        game.after(HIT_STATE_HOLD_S, function()
            -- (A map can load first, and a gone object's memory gets reused: pcall can't catch that crash, valid can.)
            if valid(comp) and comp:GetCurrentHitState().TagName:ToString() == tag then
                comp:ChangeHitState({ TagName = FName("None") }, nil, false)
            end
        end)
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
    -- every time (the widget can reset it).
    local function showAliveWord(w)
        pcall(function()
            local sw = w.PBZLanguageWidgetSwitcher_31
            sw:SetVisibility(3)
            sw:SetRenderOpacity(1)
            sw:SetActiveWidget(w.DeadRichText)
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

    function game.showAliveScreen(seconds)
        if not valid(aliveScreen) then
            aliveScreen = makeAliveScreen()
        end
        if not valid(aliveScreen) then
            return false
        end
        showAliveWord(aliveScreen)
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
                w.DeadText:SetRenderOpacity(ease)
                local s = 1.25 - 0.25 * ease
                w.DeadText:SetRenderScale({ X = s, Y = s })
                w.DeadRichText:SetRenderOpacity(math.max(0, math.min(1, (t - 0.4) / 0.5)))
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
    function game.setupGhost(ghost)
        pcall(function()
            local atk = ghost.AttributeSetBase.Attack
            atk.BaseValue = 0
            atk.CurrentValue = 0
        end)
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
    -- move, 1.5 s after the last change. With two players in a fight that flips all the time and it looks lost. So an enemy
    -- near both stays on one for FOCUS_S, by making that cooldown longer. After that it turns to the other player if they
    -- hit it lately; if not, the script goes on as it does. The script does the turning, with the other player off the
    -- list for that moment.
    local FOCUS_S = 15.0
    local FOCUS_HIT_S = 2.0       -- a hit this recent counts
    local FOCUS_REACH_CM = GHOST_AGGRO_CM   -- farther off than this a player isn't in this fight
    local focused = {}            -- enemy address -> { picker, onGuest, since, hp }
    local hitByPartner = {}       -- enemy address -> os.clock() of the partner's last hit
    local hitBySlot = {}          -- with more than two players: "<slot>:<enemy address>" -> the same

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

    local function turnTo(actor, picker, want, other)
        local hatred = actor.BP_PBZHatredManagerComponent
        if not valid(hatred) or hatred:CheckCanHatredTarget(want) == false then
            return
        end
        hatred:AddActorToHatredList(want, {})
        hatred:RemoveActorFromHatredList(other)
        picker.LastSwitchTime = 0
        picker:TrySwitchTarget()
        hatred:AddActorToHatredList(other, {})
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
                picker.SwitchTargetCooldown = LONG_S
                picker.LastSwitchTime = api.gs():GetTimeSeconds(actor)
            end
            StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary"):SetValueAsObjectByTag(actor.Controller.Blackboard,
                { TagName = FName(TARGET_KEY) }, target)
        end)
    end

    function game.partnerHit(addr, slot)
        hitByPartner[addr] = os.clock()
        if slot then
            hitBySlot[slot .. ":" .. addr] = os.clock()
        end
    end

    function game.forgetFocus()
        focused, hitByPartner, hitBySlot = {}, {}, {}
    end

    function game.steerFocus(actor, addr, x, y, z, hp, pawn, ghost)
        local at = { X = x, Y = y, Z = z }
        if not x or distance(at, pawn:K2_GetActorLocation()) > FOCUS_REACH_CM
            or distance(at, ghost:K2_GetActorLocation()) > FOCUS_REACH_CM then
            return
        end
        local target = currentTarget(actor)
        if target == nil then
            focused[addr] = nil
            return
        end
        local onGuest = target:GetAddress() == ghost:GetAddress()
        if not onGuest and target:GetAddress() ~= pawn:GetAddress() then
            return
        end
        local now, f = os.clock(), focused[addr]
        if f == nil or not valid(f.picker) then
            f = { picker = targetPicker(actor), onGuest = onGuest, since = now, hp = hp }
            focused[addr] = f
            if f.picker == nil then
                return
            end
            f.picker.SwitchTargetCooldown = FOCUS_S
        end
        local dropped = f.hp and hp and hp < f.hp - 0.5
        f.hp = hp
        if f.onGuest ~= onGuest then
            f.onGuest, f.since = onGuest, now
        end
        if now - f.since < FOCUS_S then
            return
        end
        local otherHit
        if onGuest then
            otherHit = dropped and game.localMoveRecent(FOCUS_HIT_S)
        else
            otherHit = now - (hitByPartner[addr] or -FOCUS_HIT_S) < FOCUS_HIT_S
        end
        if otherHit then
            f.since = now
            if onGuest then
                turnTo(actor, f.picker, pawn, ghost)
            else
                turnTo(actor, f.picker, ghost, pawn)
            end
        end
    end

    -- With more than two players the rule is the same: one target for FOCUS_S, then whoever hit it last among the others near
    -- it, if anyone did. Holding comes first, however much the others hit it, so a crowd can't make it spin. Turning takes all
    -- the others off the list for that moment. players: { body, addr, at, slot, mine } for each.
    function game.steerPartyFocus(actor, addr, x, y, z, hp, players)
        local at, near, on = { X = x, Y = y, Z = z }, {}, nil
        for _, who in ipairs(players) do
            if distance(at, who.at) <= FOCUS_REACH_CM then
                near[#near + 1] = who
            end
        end
        if #near < 2 then
            return
        end
        local target = currentTarget(actor)
        if target == nil then
            focused[addr] = nil
            return
        end
        local targetAddr = target:GetAddress()
        for _, who in ipairs(near) do
            if who.addr == targetAddr then
                on = who
            end
        end
        if on == nil then
            return
        end
        local now, f = os.clock(), focused[addr]
        if f == nil or not valid(f.picker) then
            f = { picker = targetPicker(actor), slot = on.slot, since = now, hp = hp }
            focused[addr] = f
            if f.picker == nil then
                return
            end
            f.picker.SwitchTargetCooldown = FOCUS_S
        end
        local dropped = f.hp and hp and hp < f.hp - 0.5
        f.hp = hp
        if f.slot ~= on.slot then
            f.slot, f.since = on.slot, now
        end
        if now - f.since < FOCUS_S then
            return
        end
        local best, bestAt = nil, now - FOCUS_HIT_S
        for _, who in ipairs(near) do
            if who ~= on then
                local hitAt = hitBySlot[who.slot .. ":" .. addr]
                if who.mine then
                    hitAt = (dropped and game.localMoveRecent(FOCUS_HIT_S)) and now or nil
                end
                if hitAt and hitAt > bestAt then
                    best, bestAt = who, hitAt
                end
            end
        end
        if best then
            f.since = now
            local hatred = actor.BP_PBZHatredManagerComponent
            if valid(hatred) and hatred:CheckCanHatredTarget(best.body) ~= false then
                hatred:AddActorToHatredList(best.body, {})
                for _, who in ipairs(near) do
                    if who ~= best then
                        hatred:RemoveActorFromHatredList(who.body)
                    end
                end
                f.picker.LastSwitchTime = 0
                f.picker:TrySwitchTarget()
                for _, who in ipairs(near) do
                    if who ~= best then
                        hatred:AddActorToHatredList(who.body, {})
                    end
                end
            end
        end
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

    ------------------------------------------------------------------ spectating

    -- While the local player is dead, the camera can follow the other player's ghost. The game's death screen is
    -- dimmed, not removed or hidden (it drives the respawn: removing it runs Refresh Monster, and a hidden widget
    -- may stop ticking), and comes back the moment we stop.
    -- The view comes from a camera of our own placed behind and above the partner every frame, looking at them:
    -- the ghost's own camera can't be used (it follows a controller the ghost doesn't have, so it sat in the
    -- bamboo looking nowhere).
    local spectating = nil        -- the actor the camera follows, or nil
    local spectateCam = nil
    local DEATH_SCREEN_DIM = 0.25
    local CAM_BACK_CM, CAM_UP_CM, CAM_FOLLOW = 380, 170, 0.12   -- behind, above, fraction of the way per frame

    local function deathScreen(pawn)
        local ok, w = pcall(function() return pawn["Death Widget"] end)
        return (ok and valid(w)) and w or nil
    end

    -- The death screen's tick is what leads to the respawn: stopped, the player waits, and it goes on from there.
    local heldScreen = nil
    function game.holdRespawn(pawn, on)
        if on then
            local w = valid(pawn) and deathScreen(pawn)
            if w and heldScreen ~= w then
                w.NotTick = true
                heldScreen = w
            end
            return heldScreen ~= nil
        end
        if valid(heldScreen) then
            pcall(function() heldScreen.NotTick = false end)
        end
        heldScreen = nil
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

    local function followFrame()
        if not (spectating and valid(spectating) and valid(spectateCam)) then
            return
        end
        local want, at = camSpot(spectating)
        local cur = spectateCam:K2_GetActorLocation()
        local a = CAM_FOLLOW
        local pos = { X = cur.X + (want.X - cur.X) * a, Y = cur.Y + (want.Y - cur.Y) * a, Z = cur.Z + (want.Z - cur.Z) * a }
        spectateCam:K2_SetActorLocationAndRotation(pos, aim(pos, at), false, {}, true)
        game.after(0.016, followFrame)
    end

    function game.spectate(target)
        local pc, pawn = api.getPlayer1()
        if not valid(pc) or not valid(pawn) then
            return false
        end
        local follow = valid(target) and target or nil
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
            game.after(0.016, followFrame)
        end
        return ok
    end

    function game.isSpectating()
        return spectating ~= nil
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
    -- step that puts it in the world. No ability, as a ghost hasn't got one.
    function game.fireBullet(owner, data, x, y, z, pitch, yaw, roll)
        local fired = {}
        local ok = pcall(function()
            lib("/Script/SGameCombatSystem.Default__BulletSpawnBurst"):SpawnBullets(owner, nil, nil, data,
                { Rotation = toQuat(pitch, yaw, roll), Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }, fired)
        end)
        if not ok or #fired == 0 then
            return false
        end
        for i = 1, #fired do
            pcall(function() fired[i]:get():Start() end)
        end
        return true
    end

    ------------------------------------------------------------------ currency (dust)

    -- Dust gained locally (kill rewards, pickups) goes to the other player too: shared rewards. Spending isn't
    -- mirrored. Amounts the mod itself added for the other player are not sent back.
    local lastDust, syncedDust = nil, 0

    local function dust(pawn)
        local ok, v = pcall(function() return pawn.ConsciousnessDust end)
        return ok and tonumber(v) or nil
    end

    function game.watchCurrency(pawn, sendEvent)
        local d = dust(pawn)
        if d == nil then
            return
        end
        if lastDust ~= nil then
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
            log("Shared dust: +" .. amount)
        end
    end

    ------------------------------------------------------------------ items

    local watched = {}            -- pickup name -> { itemId } for pickups near the local player last tick
    local takenHere = {}          -- pickup name -> true once the local player took it (until the next bell rest)

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
        if not maySearch() then
            return false          -- the caller comes back in a tenth of a second
        end
        searched()
        local here = pawn:K2_GetActorLocation()
        local all = FindAllOf("PBZPickupActor") or {}
        local map = game.mapName(pawn)
        if map ~= watchedMap or (#all == 0 and next(watched) ~= nil) then
            if map ~= watchedMap then
                takenHere = {}    -- pickup names are only unique within a map
                pickupSpots = {}
            end
            watchedMap = map
            watched = {}
        end
        local present, spots, newOnes = {}, {}, 0
        for _, p in ipairs(all) do
            local addr = p:GetAddress()
            local spot = pickupSpots[addr]
            if spot == nil and newOnes < NEW_PICKUPS_PER_PASS and valid(p) then
                newOnes = newOnes + 1
                local okL, loc = pcall(function() return p:K2_GetActorLocation() end)
                if okL and loc.X then
                    spot = { name = p:GetFName():ToString(), loc = loc }
                end
            end
            spots[addr] = spot
            if spot and (watched[spot.name] or distance(spot.loc, here) <= PICKUP_WATCH_CM + PICKUP_JUMP_CM) and valid(p) then
                local okP, pickable = pcall(function() return p.bIsPickable end)
                local okL, loc = pcall(function() return p:K2_GetActorLocation() end)
                if (not okP or pickable ~= false) and okL and loc.X then
                    present[spot.name] = { actor = p, loc = loc }
                end
            end
        end
        pickupSpots = spots
        for name, info in pairs(watched) do
            local now = present[name]
            if now == nil or distance(now.loc, info.loc) > PICKUP_JUMP_CM then
                takenHere[name] = true
                report(name, info.itemId)
                present[name] = nil
            end
        end
        watched = {}
        for name, p in pairs(present) do
            if distance(p.loc, here) <= PICKUP_WATCH_CM then
                watched[name] = { itemId = pickupItemId(p.actor), loc = p.loc }
            end
        end
    end

    -- The other player took this pickup: remove our copy and give us the same item, so loot is shared.
    function game.takeRemotePickup(name, itemId, pawn, kind)
        if takenHere[name] then
            -- Both players grabbed it within the same moment: each already has theirs, as in single-player.
            log("The other player took " .. name .. " too; you already have yours.")
            return
        end
        for _, p in ipairs(FindAllOf("PBZPickupActor") or {}) do
            if valid(p) and p:GetFName():ToString() == name then
                watched[name] = nil
                p:K2_DestroyActor()
                break
            end
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
        if game.granting or os.clock() < ownUntil or id == "None" or count < 1 then
            return
        end
        givenHere[id .. "x" .. count] = os.clock()
        send(id, count, kind or "-")
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
    function game.receiveGift(pawn, id, count, kind, from)
        local key = id .. "x" .. count
        local here = givenHere[key]
        if here and os.clock() - here < SAME_GIFT_S then
            log("The game gave " .. id .. " here too: one each.")
            return
        end
        if from then
            local last = gotFrom[key]
            if last and last.from ~= from and os.clock() - last.at < SAME_GIFT_S then
                log("Two players got " .. id .. ": one each.")
                return
            end
            gotFrom[key] = { from = from, at = os.clock() }
        end
        if gearKnown then
            gearKnown[id] = true
        end
        game.grantLoot(pawn, id, kind, count)
    end

    -- Each world has its own copy of every chest and rubbish pile, named alike. Its items reach the partner as above, so
    -- their copy only has to stop paying: a chest counts as opened, a pile goes, as a pickup's copy does. One that isn't
    -- loaded there goes as soon as it is. (A chest that's locked until a boss dies stays locked for both.)
    local CHEST_CLASS, PILE_CLASS = "BP_Chest_C", "BP_Rubbish_C"
    local PILE_SEARCHED = "/Game/PBZContent/Blueprint/Item/Device/BP_Rubbish.BP_Rubbish_C:OnInteract"
    local CHEST_WATCH_CM = 2000     -- a chest that opens after being this close to the player: they opened it
    local closedNear, retiring, searched = {}, {}, {}
    local pileHooked = false

    -- Sync stopped: dust earned and things taken alone from now on aren't news for the next partner.
    function game.forgetLink()
        lastDust, syncedDust = nil, 0
        gearKnown = nil
        watched = {}
        closedNear = {}
    end

    local function chestOpen(chest)
        local ok, open, started = pcall(function() return chest.CurSwitchState, chest.bInteracted end)
        return not ok or open == true or started == true
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
                    report(name)
                end
            end)
        end)
    end

    -- Once a second: a chest that was near this player and closed, and now isn't, they opened.
    function game.watchChests(pawn, report)
        local here = pawn:K2_GetActorLocation()
        local closed = {}
        for _, c in ipairs(FindAllOf(CHEST_CLASS) or {}) do
            if valid(c) then
                local name = c:GetFName():ToString()
                if chestOpen(c) then
                    retiring[name] = nil
                    if closedNear[name] then
                        report(name)
                    end
                elseif retiring[name] then
                    retiring[name] = nil
                    pcall(function() c:SwitchWithoutPlaySequence() end)
                elseif closedNear[name] or distance(c:K2_GetActorLocation(), here) <= CHEST_WATCH_CM then
                    closed[name] = true         -- (Near once is enough: the player can walk off while it opens.)
                end
            end
        end
        closedNear = closed
        if next(retiring) then
            for _, p in ipairs(FindAllOf(PILE_CLASS) or {}) do
                if valid(p) and retiring[p:GetFName():ToString()] then
                    retiring[p:GetFName():ToString()] = nil
                    pcall(function() p:K2_DestroyActor() end)
                end
            end
        end
    end

    function game.partnerOpened(name)
        local isPile = name:find("^BP_Rubbish") ~= nil
        closedNear[name] = nil
        for _, c in ipairs(FindAllOf(isPile and PILE_CLASS or CHEST_CLASS) or {}) do
            if valid(c) and c:GetFName():ToString() == name then
                if isPile then
                    pcall(function() c:K2_DestroyActor() end)
                elseif not chestOpen(c) then
                    pcall(function() c:SwitchWithoutPlaySequence() end)
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
    function game.inCutscene()
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
        seqOrphanSince = seqOrphanSince or os.clock()
        return os.clock() - seqOrphanSince < SEQ_ORPHAN_S
    end

    function game.mapName(contextActor)
        local ok, name = pcall(function() return api.gs():GetCurrentLevelName(contextActor, true):ToString() end)
        return ok and name or "?"
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
