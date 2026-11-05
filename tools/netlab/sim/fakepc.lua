-- One PC with no game on it: the Lua globals UE4SS gives the mod, a file system in memory, a clock that only moves when the
-- test says so, and as much of the game as the online code touches. Each PC loads the mod's real scripts into a world of its
-- own, so four of them in one Lua state know each other only through the relay in simrelay.lua.
--
-- Objects act like UObjects: what's not defined here is nil, as a wrong name would be in the game. Every call or write that
-- changes something goes into pc.trace, so two runs can be compared call by call (two.lua).

local Fake = {}

local READING = { "^Get", "^K2_Get", "^Is", "^Find", "^Check", "^Can", "^Montage_Get", "^ToString$", "^Project" }

local function reads(name)
    for _, pattern in ipairs(READING) do
        if name:find(pattern) then
            return true
        end
    end
    return false
end

local function show(v)
    if type(v) == "number" then
        return math.type(v) == "integer" and tostring(v) or string.format("%.3f", v)
    elseif type(v) == "function" then
        return "function"
    elseif type(v) == "table" then
        local class = rawget(v, "__class")
        if class then
            return class
        end
        if v.X then
            return string.format("(%.1f %.1f %.1f)", v.X, v.Y or 0, v.Z or 0)
        end
        if v.Yaw then
            return string.format("yaw %.1f", v.Yaw)
        end
        return "{}"
    end
    return tostring(v)
end

local function record(pc, class, name, ...)
    if pc.quiet then
        return
    end
    local parts = { string.format("%.3f", pc.now), class, name }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = show((select(i, ...)))
    end
    pc.trace[#pc.trace + 1] = table.concat(parts, " ")
end

local Common = {
    IsValid = function(self) return rawget(self, "__alive") end,
    GetAddress = function(self) return rawget(self, "__addr") end,
    GetClass = function(self) return rawget(self, "__classObject") or self end,
    GetFName = function(self)
        local name = rawget(self, "__name") or rawget(self, "__class")
        return { ToString = function() return name end }
    end,
    GetFullName = function(self) return "Fake " .. tostring(rawget(self, "__path") or rawget(self, "__class")) end,
    IsA = function() return true end,
    ForEachProperty = function() end,
}

local function makeMeta(pc)
    return {
        __index = function(t, k)
            pc.calls = pc.calls + 1
            local f = rawget(t, "__fields")[k]
            if f ~= nil then
                return f
            end
            if Common[k] then
                return Common[k]
            end
            if rawget(t, "__open") then           -- UI: anything goes, and nothing about it is tested
                return function() end
            end
            pc.missing[rawget(t, "__class") .. "." .. tostring(k)] = true
            return nil
        end,
        __newindex = function(t, k, v)
            record(pc, rawget(t, "__class"), "set " .. tostring(k), v)
            rawget(t, "__fields")[k] = v
        end,
    }
end

-- Writes without leaving a trace: the test's own hand on the world.
local function put(o, k, v)
    rawget(o, "__fields")[k] = v
end

local function object(pc, class, fields, open)
    pc.nextAddress = pc.nextAddress + 16
    local o = { __addr = pc.nextAddress, __class = class, __alive = true, __fields = {}, __open = open }
    setmetatable(o, pc.meta)
    for k, v in pairs(fields or {}) do
        put(o, k, v)
    end
    return o
end

-- A method that goes into the trace unless it only reads.
local function def(pc, o, name, fn)
    local class = rawget(o, "__class")
    local quietly = reads(name)
    put(o, name, function(self, ...)
        if not quietly then
            record(pc, class, name, ...)
        end
        if fn then
            return fn(self, ...)
        end
    end)
end

local function defs(pc, o, list)
    for name, fn in pairs(list) do
        def(pc, o, name, fn or nil)
    end
end

local function attribute(pc, value)
    return object(pc, "Attr", { BaseValue = value, CurrentValue = value })
end

local function list(items)
    return {
        ForEach = function(_, fn)
            for i, v in ipairs(items) do
                fn(i, { get = function() return v end })
            end
        end,
        items = items,
    }
end

local function name(text)
    return { ToString = function() return text end }
end

function Fake.character(pc, class, x, y, z, hp, posture)
    local a = object(pc, class)
    put(a, "loc", { X = x, Y = y, Z = z })
    put(a, "yaw", 0.0)
    put(a, "dead", false)
    put(a, "AttributeSetBase", object(pc, "Attributes", {
        Health = attribute(pc, hp), Health_Max = attribute(pc, hp), Health_Min = attribute(pc, 0), Attack = attribute(pc, 50),
        Shachi = attribute(pc, posture or 100), Shachi_Max = attribute(pc, posture or 100), Level = attribute(pc, 1),
        ShachiAttack = attribute(pc, 50), Infliction_Max = attribute(pc, 100), BreakDurationAdditionalMultiplier = attribute(pc, 1),
        UltimateCharge = attribute(pc, 0), UltimateChargeCount = attribute(pc, 0),
    }))
    local cmc = object(pc, "Movement", { MovementMode = 1, Velocity = { X = 0.0, Y = 0.0, Z = 0.0 }, MaxWalkSpeed = 0, AirControl = 0,
        MaxAcceleration = 0, bRunPhysicsWithNoController = false, bOrientRotationToMovement = true })
    defs(pc, cmc, { SetMovementMode = function(self, mode) put(self, "MovementMode", mode) end, DisableMovement = false,
        IsFalling = function() return false end })
    put(a, "CharacterMovement", cmc)
    local capsule = object(pc, "Capsule")
    defs(pc, capsule, { SetCollisionResponseToChannel = false })
    put(a, "CapsuleComponent", capsule)
    local anim = object(pc, "Anim", { montage = nil })
    defs(pc, anim, {
        GetCurrentActiveMontage = function(self) return rawget(self, "__fields").montage end,
        Montage_GetPosition = function() return 0.25 end,
        Montage_Play = function(self, m) put(self, "montage", m) put(self, "paused", nil) put(self, "played", (rawget(self, "__fields").played or 0) + 1) return 1.0 end,
        Montage_Stop = function(self) put(self, "montage", nil) put(self, "paused", nil) end,
        Montage_Pause = function(self, m) put(self, "paused", m) end,
    })
    local mesh = object(pc, "Mesh", { children = {}, shown = true })
    defs(pc, mesh, { GetAnimInstance = function() return anim end,
        GetNumChildrenComponents = function(self) return #rawget(self, "__fields").children end,
        GetChildComponent = function(self, i) return rawget(self, "__fields").children[i + 1] end,
        SetVisibility = function(self, on) put(self, "shown", on) end })
    put(a, "Mesh", mesh)
    put(a, "anim", anim)
    local weapons = object(pc, "Weapons", { armed = false, config = nil, edgeArmed = false, edgeConfig = nil })
    local function edge(slot)
        return slot.TagName:ToString() == "Weapon.Slot.Shachi"
    end
    local edgeAnim = object(pc, "Anim", { montage = nil })
    defs(pc, edgeAnim, {
        GetCurrentActiveMontage = function(self) return rawget(self, "__fields").montage end,
        Montage_GetPosition = function() return 0.25 end,
        Montage_Play = function(self, m) put(self, "montage", m) put(self, "played", (rawget(self, "__fields").played or 0) + 1) return 1.0 end,
    })
    local edgeMesh = object(pc, "Mesh")
    defs(pc, edgeMesh, { GetAnimInstance = function() return edgeAnim end })
    local edgeActor = object(pc, "WeaponActor", { Slot = { TagName = name("Weapon.Slot.Shachi") }, WeaponMesh = edgeMesh })
    put(a, "edgeAnim", edgeAnim)
    defs(pc, weapons, {
        IsArmed = function(self, slot)
            local f = rawget(self, "__fields")
            if edge(slot) then
                return f.edgeArmed
            end
            return f.armed
        end,
        GetCurrentWeapon = function(self, slot, data)
            local f = rawget(self, "__fields")
            if edge(slot) then
                data.WeaponConfig = f.edgeConfig
            else
                data.WeaponConfig = f.config
            end
        end,
        GetCurrentWeaponIndex = function() return 0 end,
        SetSlotWeapon = function(self, slot, _, cfg) put(self, edge(slot) and "edgeConfig" or "config", cfg) end,
        SetArmed = function(self, slot, on) put(self, edge(slot) and "edgeArmed" or "armed", on) end,
        SetWeaponAndScabbardForceHide = function(self, _, _, hide) put(self, "hidden", hide) end,
        SetWeaponForceHide = function(self, _, _, hide) put(self, "edgeHidden", hide) end,
    })
    put(a, "Character Weapons Component", weapons)
    defs(pc, a, {
        K2_GetActorLocation = function(self)
            local l = rawget(self, "__fields").loc
            return { X = l.X, Y = l.Y, Z = l.Z }
        end,
        K2_GetActorRotation = function(self) return { Pitch = 0.0, Yaw = rawget(self, "__fields").yaw, Roll = 0.0 } end,
        Respawn = function(self) put(self, "respawned", (rawget(self, "__fields").respawned or 0) + 1) end,     -- (to the bell)
        -- (Swept, it stops on the floor: flat at 100 everywhere, unless pc.noFloor says there's none at a spot.)
        K2_SetActorLocation = function(self, l, sweep)
            local z = l.Z
            local from = rawget(self, "__fields").loc
            if sweep and from and z < from.Z and not (pc.noFloor and pc.noFloor(l)) then
                z = math.max(z, math.min(from.Z, 100.0))
            end
            put(self, "loc", { X = l.X, Y = l.Y, Z = z })
            return true
        end,
        K2_SetActorLocationAndRotation = function(self, l, r)
            put(self, "loc", { X = l.X, Y = l.Y, Z = l.Z })
            put(self, "yaw", r.Yaw)
            return true
        end,
        K2_SetActorRotation = function(self, r) put(self, "yaw", r.Yaw) return true end,
        K2_DestroyActor = function(self)
            rawset(self, "__alive", false)
        end,
        AddMovementInput = function(self, dir, scale)
            -- A ghost walks where it's told, one frame's worth.
            local f = rawget(self, "__fields")
            local speed = f.CharacterMovement.MaxWalkSpeed
            local step = speed * scale / 60
            f.loc = { X = f.loc.X + dir.X * step, Y = f.loc.Y + dir.Y * step, Z = f.loc.Z }
            f.push = scale
        end,
        LaunchCharacter = false,
        GetAttachedActors = function(self, list)
            if rawget(rawget(self, "__fields")["Character Weapons Component"], "__fields").edgeConfig then
                list[#list + 1] = { get = function() return edgeActor end }
            end
        end,
        SetActorHiddenInGame = function(self, on) put(self, "hidden", on) end,
        SetActorEnableCollision = false,
        IsDead = function(self) return rawget(self, "__fields").dead end,
    })
    local hit = object(pc, "HitreactComponent", { state = "None" })
    defs(pc, hit, {
        GetOwner = function() return a end,
        GetCurrentHitState = function(self) return { TagName = name(rawget(self, "__fields").state) } end,
        ChangeHitState = function(self, tag) put(self, "state", tag.TagName:ToString()) end,
    })
    put(a, "hit", hit)
    pc.hitComps[#pc.hitComps + 1] = hit
    local side = object(pc, "FactionComponent")
    defs(pc, side, { GetOwner = function() return a end, SetFactionRelationOverride = false, ClearFactionRelationOverride = false })
    pc.factions[#pc.factions + 1] = side
    return a
end

-- Things lying in the world, named alike on every PC.
function Fake.pickup(pc, id, item, x, y, z)
    local p = object(pc, "PBZPickupActor", { ItemId = name(item), bIsPickable = true })
    rawset(p, "__name", id)
    defs(pc, p, { K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end, K2_DestroyActor = function(self) rawset(self, "__alive", false) end })
    pc.pickups[#pc.pickups + 1] = p
    return p
end

-- Its lid is a skeletal mesh that keeps the last animation it was given, its glow an effect that's on until put out.
-- loot: its row in the level loot table (Fake.LEVEL_LOOT).
function Fake.chest(pc, id, x, y, z, loot)
    local mesh = object(pc, "SkeletalMeshComponent", { VisibilityBasedAnimTickOption = 4 })
    pc.chestSkeleton = pc.chestSkeleton or object(pc, "Skeleton")
    local skin = object(pc, "SkeletalMesh", { Skeleton = pc.chestSkeleton })
    defs(pc, mesh, { GetSkeletalMeshAsset = function() return skin end, SetComponentTickEnabled = false,
        PlayAnimation = function(self, anim) put(self, "anim", anim) put(self, "at", 0) end,
        SetPosition = function(self, at) put(self, "at", at) end })
    local glow = object(pc, "PBZNiagaraComponent", { on = true })
    defs(pc, glow, { Deactivate = function(self) put(self, "on", false) end, SetVisibility = false })
    local c = object(pc, "BP_Chest_C", { CurSwitchState = false, bInteracted = false, Chest = mesh, Niagara = glow, swept = true,
        ["Loot Item ID"] = name(loot or "None") })
    rawset(c, "__name", id)
    defs(pc, c, { K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        SwitchWithoutPlaySequence = function(self) put(self, "CurSwitchState", true) end,
        ["Not Swipe"] = function(self) put(self, "swept", false) end })
    pc.chests[#pc.chests + 1] = c
    return c
end

-- A kick-stone: shut until kicked, its boulder (a skeletal mesh) where it stands until then.
function Fake.stone(pc, id, x, y, z)
    local mesh = object(pc, "SkeletalMeshComponent", { at = { X = x, Y = y, Z = z }, rot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } })
    defs(pc, mesh, { K2_GetComponentLocation = function(self) return rawget(self, "__fields").at end,
        K2_GetComponentRotation = function(self) return rawget(self, "__fields").rot end,
        K2_SetWorldLocationAndRotation = function(self, at, rot) put(self, "at", at) put(self, "rot", rot) end })
    local s = object(pc, "BP_KickStone_C", { CurSwitchState = false, SkeletalMesh = mesh })
    rawset(s, "__name", id)
    defs(pc, s, { K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        SwitchWithoutPlaySequence = function(self) put(self, "CurSwitchState", true) end })
    pc.stones = pc.stones or {}
    pc.stones[#pc.stones + 1] = s
    return s
end

-- A boss arena's fog wall: a straight spline from (x1, y1) to (x2, y2) laid at z, open until closed. Its meshes block
-- (collision 3) only while it's closed, as the game's do.
function Fake.fogWall(pc, x1, y1, x2, y2, z)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    local spline = object(pc, "SplineComponent")
    defs(pc, spline, {
        FindLocationClosestToWorldLocation = function(_, at)
            local t = math.max(0, math.min(1, ((at.X - x1) * dx + (at.Y - y1) * dy) / (len * len)))
            return { X = x1 + dx * t, Y = y1 + dy * t, Z = z }
        end,
        FindRightVectorClosestToWorldLocation = function() return { X = -dy / len, Y = dx / len, Z = 0 } end,
    })
    local wall = object(pc, "BP_FogDoor_C", { Spline = spline, closed = false })
    local mesh = object(pc, "SplineMeshComponent")
    defs(pc, mesh, { GetCollisionEnabled = function() return rawget(wall, "__fields").closed and 3 or 0 end })
    defs(pc, wall, { K2_GetActorLocation = function() return { X = x1, Y = y1, Z = z } end,
        K2_GetComponentsByClass = function() return { { get = function() return mesh end } } end,
        ["Close By Mob Script"] = function(self) put(self, "closed", true) end,
        OpenByMobScript = function(self) put(self, "closed", false) end })
    pc.fogWalls = pc.fogWalls or {}
    pc.fogWalls[#pc.fogWalls + 1] = wall
    return wall
end

-- An ability of an actor running or not, as the game's list of them has it.
function Fake.running(pc, actor, class, active)
    local asc = pc.env.StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(actor)
    local items = rawget(asc, "__fields").ActivatableAbilities.Items.items
    for _, spec in ipairs(items) do
        if spec.class == class then
            spec.ActiveCount = active and 1 or 0
            return
        end
    end
    local cls = { IsValid = function() return true end, GetFName = function() return name(class) end,
        GetFullName = function() return "BlueprintGeneratedClass /Game/Fake/" .. class .. "." .. class end }
    items[#items + 1] = { class = class, ActiveCount = active and 1 or 0,
        Ability = { IsValid = function() return true end, GetClass = function() return cls end } }
end

-- An effect on a body, as the game puts one there: a system from the effects pack, on its mesh.
function Fake.effectOn(pc, actor, path, socket)
    local system = pc.found[path]
    if not system then
        system = object(pc, "NiagaraSystem")
        rawset(system, "__path", path)
        pc.found[path] = system
    end
    local fx = object(pc, "NiagaraComponent", { on = true })
    defs(pc, fx, { IsActive = function(self) return rawget(self, "__fields").on end, GetAsset = function() return system end,
        GetAttachSocketName = function() return name(socket or "None") end })
    local children = rawget(rawget(actor, "__fields").Mesh, "__fields").children
    children[#children + 1] = fx
    return fx
end

function Fake.setHealth(a, hp)
    local h = rawget(a, "__fields").AttributeSetBase.Health
    put(h, "CurrentValue", hp)
    put(h, "BaseValue", hp)
end

function Fake.health(a)
    local set = rawget(a, "__fields").AttributeSetBase
    return set.Health.CurrentValue, set.Health_Max.CurrentValue, set.Shachi_Max.CurrentValue
end

local function hatredOf(pc, owner)
    local h = object(pc, "Hatred", { HatredList = list({}), CanBeHatredNow = true })
    local items = rawget(h, "__fields").HatredList.items
    defs(pc, h, {
        AddActorToHatredList = function(_, actor)
            for _, a in ipairs(items) do
                if a == actor then
                    return
                end
            end
            if rawget(rawget(actor, "__fields").BP_PBZHatredManagerComponent or {}, "__fields")
                and rawget(actor, "__fields").BP_PBZHatredManagerComponent.CanBeHatredNow == false then
                return
            end
            items[#items + 1] = actor
        end,
        RemoveActorFromHatredList = function(_, actor)
            for i, a in ipairs(items) do
                if a == actor then
                    table.remove(items, i)
                    return
                end
            end
        end,
        CheckCanHatredTarget = function(_, actor)
            return rawget(actor, "__fields").BP_PBZHatredManagerComponent.CanBeHatredNow ~= false
        end,
    })
    put(owner, "BP_PBZHatredManagerComponent", h)
    return h
end

-- The enemy's own target picker: the nearest on its hatred list, as the game's AIScript_TargetSelector does, looked at again
-- after the cooldown. With nobody on the list it keeps the target it has, as the game's does: a boss went on swinging at the spot.
local function pick(pc, e)
    local f = rawget(e, "__fields")
    local items = rawget(f.BP_PBZHatredManagerComponent, "__fields").HatredList.items
    local best, bestD = nil, 1e18
    for _, a in ipairs(items) do
        if rawget(a, "__alive") and not rawget(a, "__fields").dead then
            local l, m = rawget(a, "__fields").loc, f.loc
            local d = (l.X - m.X) ^ 2 + (l.Y - m.Y) ^ 2
            if d < bestD then
                best, bestD = a, d
            end
        end
    end
    if best ~= nil and best ~= f.target then
        put(e, "target", best)
        put(e, "targetChanges", (f.targetChanges or 0) + 1)
    end
end

-- A rest, as the game does it: every dead enemy whose spawner still spawns is back at full health (a beaten boss's spawner
-- doesn't). Only with pc.reviveOnRest (chaos.lua): the older tests were written for a world where the dead stay dead.
function Fake.refreshMonsters(pc)
    if not pc.reviveOnRest then
        return
    end
    for i, spawner in ipairs(pc.spawners) do
        local e = pc.enemies[i]
        local sf = rawget(spawner, "__fields")
        if e and rawget(e, "__fields").dead and sf.record ~= false then
            Fake.put(e, "dead", false)
            Fake.put(e, "killedBy", nil)
            local set = rawget(rawget(e, "__fields").AttributeSetBase, "__fields")
            Fake.setHealth(e, set.Health_Max.CurrentValue)
        end
    end
end

function Fake.enemy(pc, id, class, x, y, z, hp, posture, boss)
    local e = Fake.character(pc, class, x, y, z, hp, posture)
    rawset(e, "__name", id .. "_actor")
    local f = rawget(e, "__fields")
    put(e, "BIsMonster", true)
    put(e, "boss", boss == true)
    put(e, "baseHp", hp)                -- (what a new one of its class starts with, before the mod scales it)
    put(e, "basePosture", posture or 100)
    put(e, "dustLoot", 0)
    hatredOf(pc, e)
    local picker = object(pc, "AIScript_TargetSelector_C", { LastSwitchTime = -1e9, SwitchTargetCooldown = 1.5 })
    defs(pc, picker, { TrySwitchTarget = function(self)
        put(self, "LastSwitchTime", pc.now)
        pick(pc, e)
    end })
    put(e, "picker", picker)
    local brain = object(pc, "Brain", { running = true })
    defs(pc, brain, {
        IsRunning = function(self) return rawget(self, "__fields").running end,
        StopLogic = function(self) put(self, "running", false) end,
        RestartLogic = function(self) put(self, "running", true) end,
    })
    local controller = object(pc, "AIController", { BrainComponent = brain,
        SGameAIComponent = { SpawnedAIScripts = list({ picker }) }, Blackboard = object(pc, "Blackboard") })
    put(e, "Controller", controller)
    defs(pc, e, {
        GetController = function() return controller end,
        Kill = function(self, reason)
            put(self, "dead", true)
            Fake.setHealth(self, 0)
            put(self, "killedBy", reason)
        end,
        GetCombatLootDataBySelf = function(self, _, data) data.LootDust = f.dustLoot end,
    })
    -- (As the game's blueprint spawner: a boss's never brings it back, and Save writes ShouldSpawn into the world's list.)
    local spawner = object(pc, "AISpawner", { SpawnerID = name(id), SpawnedAI = e, ShouldSpawn = true, SetShouldNotSpawnAfterDead = boss == true })
    defs(pc, spawner, {
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        ClaimSeqSpawn = function(self) put(self, "claimed", (rawget(self, "__fields").claimed or 0) + 1) end,
        IsA = function() return true end,
        Save = function(self) put(self, "record", rawget(self, "__fields").ShouldSpawn) end,
        IsShouldToSpawn = function(self)
            local r = rawget(self, "__fields").record
            if r == nil then
                return true
            end
            return r
        end,
    })
    pc.spawners[#pc.spawners + 1] = spawner
    pc.enemies[#pc.enemies + 1] = e
    return e
end

-- The game's story, as much as story.lua reads: the QA tools' table of story rows, the quest list a narrative component keeps
-- (quests by class name, branches by ID with a state: 0 not yet, 1 under way, 2 done), and the QA library that applies rows.
-- A row: its name, its quest steps, optional, and what else it sets.
Fake.STORY_ROWS = {
    { "valley-map", "", "False", maps = "PBZ_Valley_WP" },
    { "valley-wake", "Main-Valley_1_开启任务", "False" },
    { "valley-meet", "Main-Valley_1_完成任务，Side-Cry_1_开启任务", "False" },
    { "valley-camp", "", "False", tags = "camp.arrived" },
    { "valley-boss", "Boss-Puppet_S1_开启任务, Boss-Puppet_S1_完成任务", "False" },
    { "valley-loot", "", "False", items = "I_1", tags = "item.recipe" },
    { "valley-side", "Side-Cry_1_完成任务", "True" },
    { "forest-start", "Main-Forest_1_开启任务", "False" },
    { "forest-shop", "", "False", ui = "UI.VisibilityTag.Shop" },
    { "forest-end", "Main-Forest_1_完成任务", "False" },
    { "well-yes", "Well-Ask_3-A_开启任务", "True" },        -- (a choice: yes is 3-A, no would be 3-B)
}

function Fake.story(pc)
    local rows = Fake.STORY_ROWS
    pc.quests, pc.storyMarks, pc.storyApplied = {}, {}, {}
    local nc = object(pc, "PBZNarrativeComponent", { QuestList = {}, bCompleteLoad = true })
    pc.narrative = nc
    local function branchOf(quest, id)
        local q = pc.quests[quest]
        if q == nil then
            q = object(pc, "Quest", { Branches = {} })
            rawset(q, "__name", quest .. "_C")
            pc.quests[quest] = q
            table.insert(rawget(nc, "__fields").QuestList, q)
        end
        for _, b in ipairs(rawget(q, "__fields").Branches) do
            if rawget(b, "__fields").ID:ToString() == id then
                return b
            end
        end
        local b = object(pc, "QuestBranch", { ID = name(id), state = 0 })
        defs(pc, b, { GetBranchState = function(self) return rawget(self, "__fields").state end })
        table.insert(rawget(q, "__fields").Branches, b)
        return b
    end
    -- The test's hand: a branch at least this far along.
    pc.storyStep = function(quest, id, state)
        local b = branchOf(quest, id)
        put(b, "state", math.max(rawget(b, "__fields").state, state))
    end
    pc.storyState = function(quest, id)
        local q = pc.quests[quest]
        for _, b in ipairs(q and rawget(q, "__fields").Branches or {}) do
            if rawget(b, "__fields").ID:ToString() == id then
                return rawget(b, "__fields").state
            end
        end
        return nil
    end
    local function apply(rowName)
        for _, r in ipairs(rows) do
            if r[1] == rowName then
                pc.storyApplied[#pc.storyApplied + 1] = rowName
                for entry in r[2]:gsub("，", ","):gmatch("[^,]+") do
                    local quest, id, step = entry:match("^%s*(.+)_([^_]+)_([^_]+)%s*$")
                    pc.storyStep(quest, id, step == "完成任务" and 2 or 1)
                end
                for _, k in ipairs({ "tags", "maps", "ui", "items" }) do
                    if r[k] then
                        pc.storyMarks[r[k]] = true
                    end
                end
            end
        end
    end
    -- A save that has come this far: the first n rows, as the QA tools would apply them.
    pc.storyUpTo = function(n)
        for i = 1, n do
            apply(rows[i][1])
        end
        pc.storyApplied = {}
    end
    local tables = object(pc, "DataTableFunctionLibrary")
    local COLUMNS = { QuestList = 2, Optional = 3 }
    local OTHER = { AddTags = "tags", ActiveBellMaps = "maps", ActivateUITags = "ui", AddItems = "items" }
    local levelLoot = object(pc, "DataTable")
    defs(pc, tables, {
        GetDataTableRowNames = function(_, t, out)
            if t == levelLoot then
                for i, r in ipairs(Fake.LEVEL_LOOT) do
                    out[i] = { get = function() return name(r[1]) end }
                end
                return
            end
            for i, r in ipairs(rows) do
                out[i] = name(r[1])
            end
        end,
        GetDataTableColumnAsString = function(_, t, column)
            local c, out = column:ToString(), {}
            if t == levelLoot then
                for i, r in ipairs(Fake.LEVEL_LOOT) do
                    out[i] = { get = function() return name(c == "EntryDatas" and r[2] or "") end }
                end
                return out
            end
            for i, r in ipairs(rows) do
                out[i] = name((COLUMNS[c] and r[COLUMNS[c]]) or (OTHER[c] and r[OTHER[c]]) or "")
            end
            return out
        end,
    })
    local lib = object(pc, "PBZDebugFlowEventLibrary")
    defs(pc, lib, {
        ApplyFlowEvents = function(_, _, _, _, names)
            for _, n in ipairs(names) do
                apply(n:ToString())
            end
        end,
    })
    return {
        ["/Game/PBZContent/Blueprint/FlowGraph/DebugUI/FlowQuest/FlowEventTable.FlowEventTable"] = object(pc, "DataTable"),
        ["/Game/PBZContent/Blueprint/FlowGraph/DebugUI/FlowQuest/FlowQuestBranchStateDataTable.FlowQuestBranchStateDataTable"] =
            object(pc, "DataTable"),
        ["/Script/Engine.Default__DataTableFunctionLibrary"] = tables,
        ["/Script/ProjectPBZ.Default__PBZDebugFlowEventLibrary"] = lib,
        ["/Game/PBZContent/DataTable/DT_LevelLootDataTable.DT_LevelLootDataTable"] = levelLoot,
    }
end

-- What's placed in the world, as the game's table has it: rows of { loot id, EntryDatas as its text }.
Fake.LEVEL_LOOT = {
    { "Xigu.004.Weapon_Material_04", '((EnemyLevel=0,LootDusts=((MinDust=441,MaxDust=441,CycleDustMultipliers=(1.000000,10.900000),'
        .. 'Probability=1.000000)),LootItems=((ItemId="Weapon_Material_04",MinAmount=6,MaxAmount=6,Probability=1.000000),'
        .. '(ItemId="Weapon_Material_13",MinAmount=2,MaxAmount=2,Probability=1.000000)),Weapons=((WeaponID="ShachiHook",'
        .. 'IsMainWeapon=False,Probability=1.000000)),Medicines=((MedicineID="NingFengDan",MinDust=5400,MaxDust=5400,'
        .. 'CycleDustMultipliers=(0.000000,10.900000),Probability=1.000000)),Accessories=((AccessoryID="AC_Deflect",'
        .. 'Probability=1.000000)),ItemLevel=B))' },
    { "Xigu.AC_Deflect", '((EnemyLevel=0,LootDusts=,LootItems=,Weapons=,Medicines=,Accessories=((AccessoryID="AC_Deflect",'
        .. 'Probability=1.000000)),ItemLevel=S))' },
}

function Fake.sceneManager(pc)
    local m = object(pc, "PBZLevelSequenceManager", { playing = false, ActiveSessionPlayer = nil, sequence = nil, frames = 240 })
    defs(pc, m, {
        IsInSequence = function(self) return rawget(self, "__fields").playing end,
        GetCurrentSequence = function(self) return rawget(self, "__fields").sequence end,
        -- (The manager stands in for its own sequence player.)
        GetFrameDuration = function(self) return rawget(self, "__fields").frames end,
        GetFrameRate = function() return { Numerator = 30, Denominator = 1 } end,
        GoToEndAndStop = function(self)
            put(self, "playing", false)
            put(self, "skipped", (rawget(self, "__fields").skipped or 0) + 1)
        end,
    })
    put(m, "ActiveSessionPlayer", m)
    return m
end

-- Something to use: a chest, a pile, a bell (a checkpoint), or what only looks like one.
function Fake.switch(pc, class, x, y, z, bell, noState)
    local s = object(pc, class, { InteractPlayer = nil, opened = 0 })
    rawset(s, "__name", class)
    if not noState then
        put(s, "CurSwitchState", false)
    end
    defs(pc, s, {
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        GetActorBounds = function(_, _, o, e)
            o.X, o.Y, o.Z = x, y, z
            e.X, e.Y, e.Z = 50, 50, 50
        end,
        GetMoveToTarget = function(_, loc, rot)
            loc.X, loc.Y, loc.Z = x - 100, y, z
            rot.Yaw = 0.0
        end,
        FinishMoveToAsync = function(self) put(self, "opened", rawget(self, "__fields").opened + 1) end,
        CancelMoveTo = function(self) put(self, "cancelled", true) end,
        GetComponentByClass = function() return nil end,
        IsA = function() return bell == true end,
    })
    pc.switches[#pc.switches + 1] = s
    return s
end

-- The game's limits on how far a camera tilts, on the first controller's, and the engine's on any other.
function Fake.cameras(pc, second)
    rawget(pc.controller, "__fields").PlayerCameraManager = { IsValid = function() return true end, ViewPitchMin = -80.0, ViewPitchMax = 45.0 }
    local theirs = { IsValid = function() return true end, ViewPitchMin = -89.9, ViewPitchMax = 89.9 }
    rawget(second, "__fields").PlayerCameraManager = theirs
    return theirs
end

-- A skill on a Soul, as training leaves it, and what's been given to one.
function Fake.ability(pc, soul, class)
    local name = { ToString = function() return class end }
    local k = { IsValid = function() return true end, GetFName = function() return name end }
    local asc = pc.env.StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(soul)
    local items = rawget(asc, "__fields").ActivatableAbilities.Items.items
    items[#items + 1] = { Ability = { GetClass = function() return k end } }
    return k
end
function Fake.given(soul)
    return rawget(soul, "__given") or {}
end

-- A flow actor: a switch to the eye, but it isn't one of the game's switches.
function Fake.flow(pc, class, x, y, z)
    local f = Fake.switch(pc, class, x, y, z)
    pc.switches[#pc.switches] = nil
    pc.flows = pc.flows or {}
    pc.flows[#pc.flows + 1] = f
    return f
end

-- Something with a place in the game's optimizer that isn't a Soul. What it's asked for is counted.
function Fake.flower(pc, x, y, z)
    local asked = {}
    local methods = {
        IsValid = function() return true end,
        IsA = function() return false end,
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
    }
    local owner = setmetatable({}, { __index = function(_, name)
        if methods[name] then
            return methods[name]
        end
        asked[#asked + 1] = name
        return nil
    end })
    pc.proxies = pc.proxies or {}
    pc.proxies[#pc.proxies + 1] = {
        IsValid = function() return true end,
        GetOwner = function() return owner end,
        GetAddress = function() return 7000 + #pc.proxies end,
        DisableAllOptimizations = function() end,
        EnableOptimizations = function() end,
    }
    return asked
end

-- A page of the game's, by class. Take it away from pc.screens again to close it.
function Fake.screen(pc, class)
    local name = { ToString = function() return class end }
    local s = {
        IsValid = function() return true end,
        IsActivated = function() return true end,
        IsVisible = function() return true end,
        GetClass = function() return { GetFName = function() return name end } end,
    }
    pc.screens[#pc.screens + 1] = s
    return s
end

-- The game's rumble and camera shake, on the first controller as it plays them.
function Fake.rumble(pc)
    local path = "/Script/Engine.PlayerController:ClientPlayForceFeedback_Internal"
    local effect = object(pc, "ForceFeedbackEffect")
    local self = { get = function() return pc.controller end }
    for _, fn in ipairs(pc.hooks[path] or {}) do
        fn(self, { get = function() return effect end })
    end
    put(pc.controller, "rumble", effect)
    for _, fn in ipairs(pc.afterHooks[path] or {}) do
        fn(self)
    end
    return effect
end

function Fake.shake(pc)
    local path = "/Script/Engine.PlayerController:ClientStartCameraShake"
    local scale = 1.0
    for _, fn in ipairs(pc.hooks[path] or {}) do
        fn({ get = function() return pc.controller end }, { get = function() end }, { set = function(_, v) scale = v end })
    end
    return scale
end

-- The end of the game's walk up to a thing, some time after the press: what starts then sees who "the player" is.
function Fake.arrive(pc, thing)
    local path = "/Script/ProjectPBZ.PBZSwitchBase:FinishMoveToAsync"
    local self = { get = function() return thing end }      -- (a hook's params come wrapped, as UE4SS gives them)
    for _, fn in ipairs(pc.hooks[path] or {}) do
        fn(self)
    end
    put(thing, "theplayer", rawget(pc.controller, "__fields").Pawn)
    rawget(thing, "__fields").FinishMoveToAsync(thing)
    for _, fn in ipairs(pc.afterHooks[path] or {}) do
        fn(self)
    end
end

-- What a chest's opening does whoever is at it: the first player's half cut to a shot. Stop it with the third answer.
function Fake.chestScene(pc, chest)
    local camera = object(pc, "CineCameraActor")
    local m = object(pc, "AnimMontage")
    local sequence = object(pc, "LevelSequencePlayer", { playing = true, cutsOff = false })
    put(sequence, "IsPlaying", function(self) return rawget(self, "__fields").playing end)
    put(sequence, "SetDisableCameraCuts", function(self, off) put(self, "cutsOff", off) end)
    local actor = object(pc, "LevelSequenceActor", { SequencePlayer = sequence })
    put(chest, "OpenChestAnim", m)
    put(chest, "Pickup Items", function(self) put(self, "paid", (rawget(self, "__fields").paid or 0) + 1) end)
    put(chest, "FinishMoveToAsync", function(self)
        put(self, "opened", rawget(self, "__fields").opened + 1)
        put(self, "LevelSequenceActor", actor)
        put(pc.controller, "viewTarget", camera)
    end)
    return camera, m, sequence
end

-- A drink as the game makes it: a body drinking, then the count, then the effect on whoever player 0's controller holds.
function Fake.drink(pc, body, item, share)
    local anim = rawget(body, "__fields").anim
    local m = object(pc, "AnimMontage")
    rawset(m, "__name", "AM_Hun_Medicine_Unarmed")
    put(anim, "montage", m)
    local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
    local id = { get = function() return name(item or "Hulu") end }
    local function run(list, ...)
        for _, fn in ipairs(list or {}) do
            fn(nil, ...)
        end
    end
    run(pc.hooks[BACKPACK .. ":UseMedicine"], id)
    if not item then
        put(pc.gourd, "CurrentTime", rawget(pc.gourd, "__fields").CurrentTime - 1)
    end
    run(pc.hooks[BACKPACK .. ":ActivateMedicineGameplayEffect"])
    local who = rawget(pc.controller, "__fields").Pawn
    Fake.setHealth(who, math.min(1000, Fake.health(who) + (share or 400)))
    pc.glowedOn = who
    run(pc.afterHooks[BACKPACK .. ":ActivateMedicineGameplayEffect"])
    put(anim, "montage", nil)
end

-- One entry in the game's list of live bullets.
function Fake.bullet(pc, owner, data, x, y, z, solid, parent)
    local b = object(pc, "Bullet", { BulletOwnerAvatar = owner, BulletData = data, bWasInitializedWithParentBullet = parent })
    defs(pc, b, {
        IsA = function() return solid end,
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        K2_GetActorRotation = function() return { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } end,
    })
    pc.liveBullets[#pc.liveBullets + 1] = b
    return b
end

-- The AI of an enemy nobody stopped: it looks at its target again when its cooldown is up.
function Fake.thinkEnemies(pc)
    for _, e in ipairs(pc.enemies) do
        local f = rawget(e, "__fields")
        local picker = rawget(f.picker, "__fields")
        if rawget(f.Controller, "__fields").BrainComponent and not f.dead
            and rawget(rawget(f.Controller, "__fields").BrainComponent, "__fields").running
            and pc.now - picker.LastSwitchTime >= picker.SwitchTargetCooldown then
            picker.LastSwitchTime = pc.now
            pick(pc, e)
        end
    end
end

-- Files, in memory, by name: all the mod's are in one folder.
local function files(pc)
    local function base(path)
        return (path:gsub("\\", "/"):match("([^/]+)$"))
    end
    local fs = {}
    function fs.open(path, mode)
        local key = base(path)
        mode = mode or "r"
        if mode:find("r") then
            local text = pc.files[key]
            if text == nil then
                return nil
            end
            local pos = 1
            return {
                read = function(_, what)
                    if what == "a" then
                        local rest = text:sub(pos)
                        pos = #text + 1
                        return rest
                    end
                    return nil
                end,
                lines = function() return text:gmatch("[^\n]+") end,
                seek = function() return #text end,
                close = function() end,
            }
        end
        local out = {}
        return {
            write = function(self, s)
                out[#out + 1] = s
                return self
            end,
            close = function() pc.files[key] = table.concat(out) end,
        }
    end
    function fs.remove(path)
        pc.files[base(path)] = nil
        return true
    end
    function fs.rename(a, b)
        pc.files[base(b)] = pc.files[base(a)]
        pc.files[base(a)] = nil
        return true
    end
    return fs
end

function Fake.new(id, scripts, ini, link)
    local pc = { id = id, scripts = scripts, now = 100.0, trace = {}, logs = {}, errors = {}, missing = {}, files = {}, loops = {}, hooks = {},
        nextAddress = 0x100000, calls = 0, keys = {}, enemies = {}, spawners = {}, spawned = {}, hitComps = {}, factions = {}, pickups = {}, chests = {}, link = link, map = "Map_Xigu",
        paused = false }
    pc.meta = makeMeta(pc)
    pc.files["PhantomPact.ini"] = ini
    pc.files["enabled.txt"] = ""

    local world = {}
    pc.world = world
    local pawnClass = object(pc, "BP_Renewal_Hun_C")
    pc.pawnClass = pawnClass
    local function newPawn(x, y, z)
        local p = Fake.character(pc, "BP_Renewal_Hun_C", x, y, z, 1000, 100)
        rawset(p, "__classObject", pawnClass)
        hatredOf(pc, p)
        put(p, "ConsciousnessDust", 0)
        put(p, "ChangeDustNumInternal", function(self, n)
            record(pc, "Pawn", "ChangeDustNumInternal", n)
            put(self, "ConsciousnessDust", rawget(self, "__fields").ConsciousnessDust + n)
        end)
        put(p, "GiveItem", function(self, id, n)
            pc.bag:AddPropsToBackPack(n, id, false)
        end)
        local ic = object(pc, "PBZInteractComponent", { used = {}, InteractingActor = nil, LocalPlayerSubsystem = nil })
        defs(pc, ic, {
            GetOwner = function() return p end,
            DoInteract = function(self, target)
                local used = rawget(self, "__fields").used
                used[#used + 1] = target
                put(self, "theplayer", rawget(pc.controller, "__fields").Pawn)
                if p ~= pc.pawn then
                    pc.inputSets[1] = {}
                end
                local finish = rawget(target, "__fields").FinishMoveToAsync
                if finish and not pc.walksUp then
                    finish(target)
                end
            end,
            CheckAndForceEndInteract = false,
            SetCurrentInteractActor = false,
        })
        put(ic, "CanTriggerInteract", function(_, thing) return rawget(thing, "__forbidden") == nil end)
        put(ic, "IsPlayerFaceToActor", function(_, _, thing) return rawget(thing, "__behind") == nil end)
        put(ic, "PauseTimer", function(self) put(self, "paused", true) end)
        put(ic, "GetInteractActor", function() return nil end)
        put(ic, "GetInteractingActor", function(self) return rawget(self, "__fields").InteractingActor end)
        put(ic, "GetValidDistance", function(_, thing) return rawget(thing, "__seen") == true end)
        pc.interactComps[#pc.interactComps + 1] = ic
        put(p, "interact", ic)
        -- What it wears: a figure spawned here comes in this player's clothes, as the game's does.
        local own = pc.pawn and rawget(pc.pawn, "__fields").look
        local mine = own and rawget(own, "__fields") or {}
        local look = object(pc, "PBZAppearanceComponent", { outfit = mine.outfit or "Hun_OutFit_Default", hidden = mine.hidden == true,
            skin = mine.skin or 0, bUseConfiguredAppearance = false, suppressed = false, dressed = 0,
            CurrentOutfit = name(mine.outfit or "Hun_OutFit_Default") })
        defs(pc, look, {
            GetEffectiveOutfit = function(self) return name(rawget(self, "__fields").outfit) end,
            IsEffectiveHatHidden = function(self) return rawget(self, "__fields").hidden end,
            GetEffectiveSkinColor = function(self) return rawget(self, "__fields").skin end,
            BeginSuppressAppearanceSave = function(self) put(self, "suppressed", true) end,
            SetConfiguredAppearance = false,
            SetUseConfiguredAppearance = function(self, on) put(self, "bUseConfiguredAppearance", on) end,
            ApplyOutfitVisual = function(self, outfit, showHat, skin)
                put(self, "outfit", outfit:ToString())
                put(self, "hidden", not showHat)
                put(self, "skin", skin)
                put(self, "dressed", rawget(self, "__fields").dressed + 1)
            end,
        })
        put(p, "look", look)
        put(p, "GetComponentByClass", function(_, class)
            return (class == pc.interactClass and ic) or (class == pc.appearanceClass and look) or nil
        end)
        local points = {}
        local pointPairs = {}
        for _, kind in ipairs({ "Execution", "ShachiWeapon", "SpecialAttack" }) do
            local action = object(pc, "ActionWidget", { Icon = {} }, true)
            local widget = object(pc, "WG_ExecutePoint", { InputActionWidget = action, shown = false }, true)
            put(widget, "IsVisible", function(self) return rawget(self, "__fields").shown end)
            local point = object(pc, "WidgetComponent", {}, true)
            put(point, "SetOwnerPlayer", function(self, player) put(self, "owner", player) end)
            put(point, "GetWidget", function() return widget end)
            points[kind] = point
            pointPairs[#pointPairs + 1] = { kind, point }
        end
        put(p, "points", points)
        local execution = object(pc, "ExecutionComponent", { ExecutionWidgets = { ForEach = function(_, fn)
            for _, pair in ipairs(pointPairs) do
                fn({ get = function() return name(pair[1]) end }, { get = function() return pair[2] end })
            end
        end } }, true)
        put(p, "GetExecutionComponent", function() return execution end)
        put(p, "AddComponentByClass", function()
            local c = object(pc, "WidgetComponent", { shown = false }, true)
            put(c, "SetWidget", function(self, w) put(self, "widget", w) end)
            put(c, "SetVisibility", function(self, on) put(self, "shown", on) end)
            put(c, "IsVisible", function(self) return rawget(self, "__fields").shown end)
            put(c, "K2_SetWorldLocation", function(self, at) put(self, "at", at) end)
            put(p, "promptComp", c)
            return c
        end)
        defs(pc, p, { DisableInput = false, EnableInput = false })
        put(p, "PlayAnimMontage", function(self, m) put(self, "opening", m) return 3.3 end)
        local input = object(pc, "PBZNBInputComponent", { resets = 0 })
        put(input, "ResetToDefaultInputMode", function(self)
            put(self, "resets", rawget(self, "__fields").resets + 1)
            if p ~= pc.pawn then
                for _, c in ipairs(pc.inputContexts) do
                    pc.inputSets[1][c] = 1
                end
            end
        end)
        put(p, "PBZNBInput", input)
        put(p, "NBCamera", object(pc, "Camera", {}, true))
        return p
    end
    pc.newPawn = newPawn
    pc.interactComps, pc.switches, pc.bellMenus, pc.screens, pc.keys2, pc.loadedAt = {}, {}, {}, {}, {}, 0
    pc.afterHooks = {}
    pc.inputActions = {}
    for _, action in ipairs({ "IA_UseBottomItem" }) do
        local a = object(pc, "InputAction")
        rawset(a, "__name", action)
        pc.inputActions[#pc.inputActions + 1] = a
    end
    pc.inputSubsystems, pc.injected = {}, {}
    pc.inputContexts = { object(pc, "InputMappingContext"), object(pc, "InputMappingContext") }
    rawset(pc.inputContexts[1], "__name", "IMC_Default")
    rawset(pc.inputContexts[2], "__name", "IMC_Locomotion")
    pc.inputSets = { [0] = {}, [1] = {} }
    for _, c in ipairs(pc.inputContexts) do
        pc.inputSets[0][c], pc.inputSets[1][c] = 1, 1
    end
    for id = 0, 1 do
        local s = object(pc, "InputSubsystem", {}, true)
        put(s, "GetOuter", function() return { ControllerId = id } end)
        put(s, "HasMappingContext", function(_, c, found)
            found.OutFoundPriority = pc.inputSets[id][c]
            return pc.inputSets[id][c] ~= nil
        end)
        put(s, "AddMappingContext", function(_, c, priority) pc.inputSets[id][c] = priority end)
        put(s, "InjectInputVectorForAction", function(_, action)
            pc.injected[#pc.injected + 1] = action:GetFName():ToString()
        end)
        pc.inputSubsystems[#pc.inputSubsystems + 1] = s
    end
    local pawn = newPawn(0.0, 0.0, 100.0)
    pc.pawn = pawn
    local death = object(pc, "DeathWidget", { NotTick = false }, true)
    put(pawn, "Death Widget", death)
    pc.deathWidget = death
    local widgets = {}
    local camera = object(pc, "Camera")
    defs(pc, camera, { GetCameraRotation = function() return { Yaw = 0.0 } end, GetCameraLocation = function() return { X = 0, Y = 0, Z = 0 } end })
    local function playerController(keys, id, body)
        local c = object(pc, "PlayerController", { Pawn = body, PlayerCameraManager = camera, viewTarget = nil, ticking = id == 0, ignored = false,
            Player = object(pc, "LocalPlayer", { ControllerId = id }) })
        defs(pc, c, {
            IsInputKeyDown = function(_, key) return keys[key.KeyName:ToString()] == true end,
            SetViewTargetWithBlend = function(self, target) put(self, "viewTarget", target) end,
            GetViewTarget = function(self) return rawget(self, "__fields").viewTarget or rawget(self, "__fields").Pawn end,
            ClientPlayForceFeedback_Internal = function(self, effect) put(self, "rumble", effect) end,
            ClientStopForceFeedback = function(self, effect) put(self, "rumbleStopped", effect) end,
            IsActorTickEnabled = function(self) return rawget(self, "__fields").ticking end,
            SetActorTickEnabled = function(self, on) put(self, "ticking", on) end,
            Possess = function(self, b) put(self, "Pawn", b) end,
            UnPossess = function(self) put(self, "Pawn", nil) end,
            SetIgnoreMoveInput = function(self, on) put(self, "ignored", on) end,
            SetIgnoreLookInput = false,
            ResetIgnoreInputFlags = function(self) put(self, "ignored", false) end,
            IsMoveInputIgnored = function(self) return rawget(self, "__fields").ignored end,
            GetControlRotation = function() return { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } end,
            FlushPressedKeys = false,
        })
        return c
    end
    local controller = playerController(pc.keys, 0, pawn)
    pc.controller = controller
    local mode = object(pc, "GameMode")
    put(mode, "Refresh Monster", function()
        record(pc, "GameMode", "Refresh Monster")
        Fake.refreshMonsters(pc)
        for _, fn in ipairs(pc.hooks["/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster"] or {}) do
            fn()
        end
    end)
    local gs = object(pc, "GameplayStatics")
    defs(pc, gs, {
        GetPlayerController = function(_, _, i)
            if i == 1 then
                return pc.controller2
            end
            return controller
        end,
        CreatePlayer = function()
            pc.controller2 = playerController(pc.keys2, 1)
            -- (A controller taking a body clears player 0's control sets, whichever controller it is.)
            local takes = rawget(pc.controller2, "__fields").Possess
            put(pc.controller2, "Possess", function(self, body)
                pc.inputSets[0] = {}
                takes(self, body)
            end)
            put(pc.controller2, "ProjectWorldLocationToScreen", function(_, _, out)
                local at = pc.projected or { X = 960, Y = 810 }
                out.X, out.Y = at.X, at.Y
            end)
            return pc.controller2
        end,
        RemovePlayer = function()
            pc.controller2 = nil
        end,
        SetForceDisableSplitscreen = function(_, _, on) pc.fullWidth = on end,
        SetPlayerControllerID = false,
        GetGameMode = function() return mode end,
        IsGamePaused = function() return pc.paused end,
        SetGamePaused = function(_, _, on) pc.paused = on end,
        GetTimeSeconds = function() return pc.now end,
        GetCurrentLevelName = function() return name(pc.map) end,
        BeginDeferredActorSpawnFromClass = function(_, _, cls, t)
            if cls == pawnClass then
                local g = newPawn(t.Translation.X, t.Translation.Y, t.Translation.Z)
                pc.spawned[#pc.spawned + 1] = g
                return g
            end
            -- An enemy's class (a fake enemy is its own class): one more of it, with no spawner (twins.lua).
            local cf = type(cls) == "table" and rawget(cls, "__fields")
            if cf and cf.BIsMonster then
                pc.twinCount = (pc.twinCount or 0) + 1
                local e = Fake.enemy(pc, "spawned" .. pc.twinCount, rawget(cls, "__class"), t.Translation.X, t.Translation.Y,
                    t.Translation.Z, cf.baseHp, cf.basePosture, cf.boss)
                table.remove(pc.spawners)
                rawset(e, "__name", rawget(cls, "__name"))
                pc.spawned[#pc.spawned + 1] = e
                return e
            end
            local cam = object(pc, "CameraActor", { loc = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z } }, true)
            put(cam, "K2_GetActorLocation", function(self) return rawget(self, "__fields").loc end)
            put(cam, "K2_SetActorLocationAndRotation", function(self, l) put(self, "loc", l) end)
            return cam
        end,
        FinishSpawningActor = function(_, actor) return actor end,
    })
    local hudLayout = object(pc, "PBZHUDLayout", { bars = {} })
    defs(pc, hudLayout, {
        RegisterBossHPBar = function(_, boss)
            for _, fn in ipairs(pc.hooks["/Script/ProjectPBZ.PBZHUDLayout:RegisterBossHPBar"] or {}) do
                fn(hudLayout, { get = function() return boss end })
            end
        end,
        UnRegisterBossHPBar = function(_, boss)
            for _, fn in ipairs(pc.hooks["/Script/ProjectPBZ.PBZHUDLayout:UnRegisterBossHPBar"] or {}) do
                fn(hudLayout, { get = function() return boss end })
            end
        end,
        GetBossHPBarInstances = function() return {} end,
    })
    pc.hudLayout = hudLayout
    local gourd = object(pc, "Gourd", { CurrentTime = 2, MaxTime = 2 })
    defs(pc, gourd, { SetCurrentTime = function(self, n) put(self, "CurrentTime", n) end, SetDisplayTime = false })
    pc.gourd = gourd
    local gourds = { ForEach = function(_, fn) fn({ get = function() return name("Hulu") end }, { get = function() return gourd end }) end }
    local bag = object(pc, "Backpack", { MedicineInfos = gourds, BottomMedicineID = name("Hulu"), Accessories = list({}), items = {} })
    put(bag, "Inventories", { ForEach = function(_, fn)        -- (what's been added, as the game counts it)
        for id, n in pairs(rawget(bag, "__fields").items) do
            fn({ get = function() return name(id) end }, { get = function() return { CurrentAmount = n } end })
        end
    end })
    pc.bag = bag
    local BELL_HEAL = "/Script/ProjectPBZ.MelodiousBell:RestoreHealth"
    local bell = object(pc, "Bell")
    defs(pc, bell, { RestoreHealth = function()
        local _, maxhp = Fake.health(pawn)
        Fake.setHealth(pawn, maxhp)
        for _, fn in ipairs(pc.hooks[BELL_HEAL] or {}) do
            fn()
        end
    end })
    pc.bell = bell
    local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
    local function given(self, count, id, push)
        local key = id.ToString and id:ToString() or id
        local items = rawget(self, "__fields").items
        items[key] = (items[key] or 0) + count
        for _, fn in ipairs(pc.hooks[BACKPACK .. ":AddPropsToBackPack"] or {}) do
            fn(self, { get = function() return count end }, { get = function() return name(key) end }, { get = function() return push end })
        end
    end
    local function gotWeapon(self, id, normal, push, loading)
        for _, fn in ipairs(pc.hooks[BACKPACK .. ":AddWeaponItem"] or {}) do
            fn(self, { get = function() return id end }, { get = function() return normal end }, { get = function() return push end },
                { get = function() return loading end })
        end
    end
    defs(pc, bag, { AddPropsToBackPack = given, PushMedicineToInventory = false, PushAccessoryToInventory = false, AddWeaponItem = gotWeapon })
    local subsystems = object(pc, "SubsystemLibrary")
    pc.liveBullets, pc.fired, pc.bulletData = {}, {}, {}
    local bulletSystem = object(pc, "BulletSubsystem", { Bullets = list(pc.liveBullets) })
    defs(pc, bulletSystem, { GetBulletCount = function() return #pc.liveBullets end })
    local spawner = object(pc, "BulletSpawnBurst")
    defs(pc, spawner, { SpawnBullets = function(_, owner, _, _, data, tf, fired)
        local shot = { owner = owner, data = data, at = tf.Translation, started = false, ended = false }
        pc.fired[#pc.fired + 1] = shot
        local n = #pc.fired
        -- (Its own end, as the game's timer ends it: a copy that ended is gone, as an object.)
        local made = { Start = function() shot.started = true end,
            GetFName = function() return { ToString = function() return "PBZ_ParticleBullet_" .. n end } end,
            IsValid = function() return not shot.ended end,
            OnTimeToDestroy = function() shot.ended = true end }
        fired[#fired + 1] = { get = function() return made end }
    end })
    defs(pc, subsystems, { GetWorldSubsystem = function(_, _, cls)
        local path = rawget(cls, "__path")
        return (path == BACKPACK and bag) or (path == "/Script/SGameCombatSystem.BulletSubsystem" and bulletSystem) or nil
    end })
    local aiLibrary = object(pc, "SGameAIFunctionLibrary")
    defs(pc, aiLibrary, {
        GetTargetActor = function(_, controllerOfEnemy, out)
            for _, e in ipairs(pc.enemies) do
                if rawget(e, "__fields").Controller == controllerOfEnemy then
                    out.Target = rawget(e, "__fields").target
                end
            end
        end,
        SetValueAsObjectByTag = function(_, _, _, target)
            pc.lastAim = target
            pc.aims = (pc.aims or 0) + 1
        end,
    })
    local widgetLibrary = object(pc, "WidgetBlueprintLibrary")
    defs(pc, widgetLibrary, { SetInputMode_UIOnlyEx = false, SetInputMode_GameOnly = false, Create = function(_, _, cls, owner)
        if cls == pc.promptClass then
            local w = object(pc, "W_InteractionUI_C", { plays = 0, outs = 0, owner = owner,
                InputActionWidget_C_75 = object(pc, "ActionWidget", { Icon = {} }, true),
                InvalidationBox_0 = object(pc, "InvalidationBox", {}, true) }, true)
            put(w, "PlayNoneToInputAction", function(self) put(self, "plays", rawget(self, "__fields").plays + 1) end)
            put(w, "PlayNoneToVirtualAnimation", function(self) put(self, "ring", (rawget(self, "__fields").ring or 0) + 1) end)
            put(w, "PlayVirtualToInput", function(self) put(self, "plays", rawget(self, "__fields").plays + 1) end)
            put(w, "PlayVirtualToNone", function(self, comp)
                put(self, "outs", rawget(self, "__fields").outs + 1)
                comp:SetVisibility(false, false)
            end)
            put(w, "PlayInputActionToVirtual", function(self) put(self, "ring", (rawget(self, "__fields").ring or 0) + 1) end)
            put(w, "PlayInputActionToNone", function(self, comp)
                put(self, "outs", rawget(self, "__fields").outs + 1)
                comp:SetVisibility(false, false)
            end)
            return w
        end
        if cls == pc.hudClass then
            local w = object(pc, "W_FrontEndHUDLayout_C", { owner = owner, heldBy = controller.Pawn, bosses = {} }, true)
            put(w, "SetVisibility", function(self, v) put(self, "visibility", v) end)
            put(w, "ShowEnemyIndicator", function(self, e) rawget(self, "__fields").pointers[e] = true end)
            put(w, "RemoveEnemyIndicator", function(self, e) rawget(self, "__fields").pointers[e] = nil end)
            put(w, "pointers", {})
            pc.playerHud = w
            return w
        end
        if cls == pc.bossBarClass then
            local w = object(pc, "WB_BossHPBar_C", { owner = owner }, true)
            put(w, "Init", function(self, boss) put(self, "boss", boss) end)
            put(w, "RemoveFromParent", function(self) put(self, "removed", true) end)
            put(w, "SetVisibility", function(self, v) put(self, "visibility", v) end)
            pc.bossBars[#pc.bossBars + 1] = w
            return w
        end
        local circle = object(pc, "Image", { Brush = {} }, true)
        put(circle, "SetColorAndOpacity", function(self, tint) put(self, "tint", tint) end)
        local w = object(pc, "Widget", { Circle = circle, FadeIn = {} }, true)
        put(w, "SetColorAndOpacity", function(self, tint) put(self, "colour", tint) end)
        put(w, "IsInViewport", function() return true end)
        put(w, "SetVisibility", function(self, v) put(self, "visibility", v) end)
        put(w, "SetText", function(self, text) put(self, "lastText", tostring(text)) end)
        put(w, "SetPositionInViewport", function(self, at) put(self, "position", at) end)
        put(w, "GetDesiredSize", function() return { X = 40, Y = 40 } end)
        put(w, "RemoveFromParent", function(self) put(self, "removed", true) end)
        widgets[#widgets + 1] = w
        return w
    end })
    pc.widgets = widgets
    local layoutLibrary = object(pc, "WidgetLayoutLibrary")
    defs(pc, layoutLibrary, { GetViewportSize = function() return { X = 1920, Y = 1080 } end, GetViewportScale = function() return 1.0 end })
    -- A Hun's locomotion: its driver keeps a default gait tag, and its actor state component takes a new state by tag.
    local function locomotion(actor)
        local state = object(pc, "ActorStateComponent", { state = "CharacterState.Native.Attitude.Jogging" })
        defs(pc, state, { TryActivateNewState = function(self, tag) put(self, "state", tag.TagName:ToString()) return true end })
        local driver = object(pc, "GA_LocomotionDriver_3DDefault_C", {
            DefaultAttitudeStateTag = { TagName = name("CharacterState.Native.Attitude.Jogging") }, ActorStateComponent = state })
        put(actor, "gaitState", state)
        local cls = { IsValid = function() return true end, GetFName = function() return name("GA_LocomotionDriver_3DDefault_C") end }
        return { class = "GA_LocomotionDriver_3DDefault_C", ActiveCount = 1, NonReplicatedInstances = list({ driver }),
            Ability = { IsValid = function() return true end, GetClass = function() return cls end } }
    end
    local abilities = object(pc, "AbilitySystemLibrary")
    defs(pc, abilities, { GetAbilitySystemComponent = function(_, actor)
        local asc = rawget(actor, "__fields").asc
        if asc == nil then
            local specs = rawget(actor, "__class") == "BP_Renewal_Hun_C" and { locomotion(actor) } or {}
            asc = object(pc, "ASC", { ActivatableAbilities = { Items = list(specs) } }, true)
            put(asc, "TryActivateAbilityByClass", function(_, class) put(actor, "used", class) end)
            put(asc, "K2_GiveAbility", function(_, class)
                local given = rawget(actor, "__given") or {}
                given[#given + 1] = class
                rawset(actor, "__given", given)
            end)
            if rawget(actor, "__fields").dustLoot ~= nil then
                -- An enemy's: the only effect ever applied to one is the game's kill, its whole death, paying this PC's
                -- player as for their own blow.
                put(asc, "BP_ApplyGameplayEffectToSelf", function()
                    record(pc, "ASC", "BP_ApplyGameplayEffectToSelf")
                    Fake.setHealth(actor, 0)
                    put(actor, "dead", true)
                    put(actor, "realDeath", true)
                    -- (The loot is rolled at the enemy's level: 0 pays nothing.)
                    local set = rawget(actor, "__fields").AttributeSetBase
                    local level = rawget(rawget(set, "__fields").Level, "__fields").CurrentValue
                    local dust = rawget(actor, "__fields").dustLoot or 0
                    if dust > 0 and level > 0 and pc.pawn then
                        pc.pawn:ChangeDustNumInternal(dust)
                    end
                end)
            end
            put(actor, "asc", asc)
        end
        return asc
    end })
    local rendering = object(pc, "RenderingLibrary")
    defs(pc, rendering, { ImportFileAsTexture2D = function() return object(pc, "Texture", {}, true) end })
    -- The game's enemy codex: a row for each kind, which says whether it's a boss. (A fake enemy's class goes by its id.)
    local codex = object(pc, "DataTable")
    defs(pc, codex, { FindRow = function(_, kind)
        for _, e in ipairs(pc.enemies) do
            if (rawget(e, "__name") or ""):gsub("_C$", "") == kind and rawget(e, "__fields").boss then
                return { bIsBoss = true }
            end
        end
        return nil
    end })
    local widgetClass = object(pc, "WidgetClass")
    pc.mapWidgets = {}
    local slotProto = { GetAutoSize = function() return false end, GetSize = function() return { X = 40, Y = 40 } end,
        GetAlignment = function() return { X = 0.5, Y = 0.5 } end, GetPosition = function() return { X = 500, Y = 500 } end }
    local mapCanvas = { AddChildToCanvas = function(_, w)
        local slot = setmetatable({ SetAutoSize = function() end, SetSize = function() end, SetAlignment = function() end,
            SetPosition = function() end }, { __index = slotProto })
        put(w, "Slot", slot)
        pc.mapWidgets[#pc.mapWidgets + 1] = w
        return slot
    end }
    local playerIcon = object(pc, "WB_PlayerIcon", { Slot = slotProto })
    defs(pc, playerIcon, { GetParent = function() return mapCanvas end, GetClass = function() return widgetClass end })
    local mapScreen = object(pc, "WB_MapNew_C", { WB_PlayerIcon = playerIcon })
    put(mapScreen, "IsVisible", function() return pc.mapOpen == true end)
    local mapSystem = object(pc, "MapSubsystem")
    defs(pc, mapSystem, { GetCurrentMapID = function() return 1 end, ProjectWorldLocationToMap = function(_, at)
        return { X = 0.5 + at.X / 1e6, Y = 0.5 + at.Y / 1e6 }
    end })

    local bulletClass = object(pc, "Class")
    rawset(bulletClass, "__path", "/Script/SGameCombatSystem.BulletSubsystem")
    pc.interactClass, pc.promptClass, pc.hudClass = object(pc, "Class"), object(pc, "WidgetClass"), object(pc, "WidgetClass")
    pc.bossBarClass, pc.bossBars = object(pc, "WidgetClass"), {}
    pc.riseClass = object(pc, "Class")
    local found = {
        ["/Game/PBZContent/UI/InGame/Dead/bg_dead.bg_dead"] = object(pc, "Texture", {}, true),
        ["/Game/PBZContent/UI/InGame/Dead/T_UI_blood_Combine.T_UI_blood_Combine"] = object(pc, "Texture", {}, true),
        ["/Game/PBZContent/UI/UINew/testplaceholder/yun.yun"] = object(pc, "Texture", {}, true),
        ["/Game/PBZContent/UI/UINew/testplaceholder/ming.ming"] = object(pc, "Texture", {}, true),
        ["/Game/PBZContent/UI/InGame/Dead/GA_PlayerRespawn.GA_PlayerRespawn_C"] = pc.riseClass,
        ["/Game/PBZContent/UI/Hud/WB_BossHPBar.WB_BossHPBar_C"] = pc.bossBarClass,
        ["/Script/ProjectPBZ.PBZInteractComponent"] = pc.interactClass,
        ["/Script/UMG.WidgetComponent"] = object(pc, "Class"),
        ["/Game/PBZContent/UI/InGame/InteractionUI/W_InteractionUI.W_InteractionUI_C"] = pc.promptClass,
        ["/Game/PBZContent/UI/FrontEnd/W_FrontEndHUDLayout.W_FrontEndHUDLayout_C"] = pc.hudClass,
        ["/Script/Engine.Default__GameplayStatics"] = gs,
        ["/Script/Engine.Default__SubsystemBlueprintLibrary"] = subsystems,
        ["/Script/SGameAI.Default__SGameAIFunctionLibrary"] = aiLibrary,
        ["/Script/UMG.Default__WidgetBlueprintLibrary"] = widgetLibrary,
        ["/Script/UMG.Default__WidgetLayoutLibrary"] = layoutLibrary,
        ["/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"] = abilities,
        ["/Script/Engine.Default__KismetRenderingLibrary"] = rendering,
        ["/Script/SGameCombatSystem.Default__BulletSpawnBurst"] = spawner,
        ["/Script/EngineSettings.Default__GameMapsSettings"] = object(pc, "GameMapsSettings", {}, true),
        ["/Script/SGameCombatSystem.BulletSubsystem"] = bulletClass,
        ["/Game/PBZContent/DataTable/DT_CodexEnemyDataTable.DT_CodexEnemyDataTable"] = codex,
        ["/UltraVolumetrics/UltraVolumetrics/Core/PaintMode/Blueprint/W_PaintSize.W_PaintSize_C"] = widgetClass,
        ["/Game/PBZContent/UI/InGame/SwitchUI/WB_TipsText.WB_TipsText_C"] = widgetClass,
        ["/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster"] = object(pc, "Function"),
        ["/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:Respawn Refresh Monster"] = object(pc, "Function"),
        [BELL_HEAL] = object(pc, "Function"),
        [BACKPACK] = object(pc, "BackpackClass"),
    }
    rawset(found[BACKPACK], "__path", BACKPACK)
    for path, o in pairs(Fake.story(pc)) do
        found[path] = o
    end
    found["/Game/PBZContent/Blueprint/Ability/GameplayEffects/GE_Kill.GE_Kill_C"] = object(pc, "Class")
    found["/Script/Engine.SkeletalMeshComponent"] = object(pc, "Class")
    pc.appearanceClass = pc.appearanceClass or object(pc, "Class")
    found["/Script/ProjectPBZ.PBZAppearanceComponent"] = pc.appearanceClass
    -- Effects: spawned on a body (the ghost's), and what was spawned where.
    for _, k in ipairs({ "/Script/Niagara.NiagaraComponent", "/Script/Niagara.NiagaraSystem", "/Script/Engine.Character" }) do
        found[k] = object(pc, "Class")
    end
    pc.effectsOn = {}
    local niagara = object(pc, "NiagaraFunctionLibrary")
    defs(pc, niagara, { SpawnSystemAttached = function(_, system, on, socket)
        pc.effectsOn[#pc.effectsOn + 1] = { path = rawget(system, "__path"), on = on, socket = socket:ToString() }
    end })
    found["/Script/Niagara.Default__NiagaraFunctionLibrary"] = niagara
    pc.chestSkeleton = pc.chestSkeleton or object(pc, "Skeleton")
    for _, anim in ipairs({ "Chest_Close2Open", "Chest_Open" }) do
        local path = "/HuaShira/SceneProp/Chest/Anim/" .. anim .. "." .. anim
        found[path] = object(pc, "AnimSequence", { Skeleton = pc.chestSkeleton })
        rawset(found[path], "__path", path)
    end
    local statics = object(pc, "StaticObject", {}, true)
    pc.found = found
    pc.montages, pc.weaponConfigs = {}, {}

    local env = setmetatable({}, { __index = _G })
    pc.env = env
    env.print = function(text)
        local line = tostring(text):gsub("\n$", "")
        pc.logs[#pc.logs + 1] = line
        if line:find("net error", 1, true) or line:find(" error: ", 1, true) or line:find("Timer error", 1, true) then
            pc.errors[#pc.errors + 1] = line
        end
    end
    env.StaticFindObject = function(path)
        if found[path] then
            return found[path]
        end
        if path:find("^/PBZCombatAsset/ActorData/Move/") then
            local m = pc.montages[path]
            if m == nil then
                m = object(pc, "AnimMontage", { BlendOutTriggerTime = -1.0, BlendOut = { BlendTime = 0.25 } })
                rawset(m, "__path", path)
                defs(pc, m, { GetPlayLength = function() return 1.5 end })
                pc.montages[path] = m
            end
            return m
        end
        if path:find("^/PBZVFXPack/") then     -- (the effects are in every copy of the game)
            local system = object(pc, "NiagaraSystem")
            rawset(system, "__path", path)
            found[path] = system
            return system
        end
        if path:find("^/PBZCombatAsset/ActorData/Players/") then
            local d = pc.bulletData[path]
            if d == nil then
                d = object(pc, "BulletData")
                rawset(d, "__path", path)
                pc.bulletData[path] = d
            end
            return d
        end
        if path:find("^/PBZCombatAsset/ActorData/Weapon/") then
            local c = pc.weaponConfigs[path]
            if c == nil then
                c = object(pc, "WeaponConfig")
                rawset(c, "__path", path)
                pc.weaponConfigs[path] = c
            end
            return c
        end
        return statics.nothing
    end
    env.FindObject = function(kind) return kind == "WidgetBlueprintGeneratedClass" and widgetClass or nil end
    env.FindFirstOf = function(class)
        if class == "PlayerController" then
            return controller
        elseif class == "PBZHUDLayout" then
            return hudLayout
        elseif class == "MapSubsystem" then
            return mapSystem
        elseif class == "MelodiousBell" then
            return bell
        elseif class == "PBZLevelSequenceManager" then
            return pc.scene
        elseif class == "PBZNarrativeComponent" then
            return pc.narrative
        end
        return nil
    end
    env.FindAllOf = function(class)
        if class == "PBZCharacter_NPC" then
            return pc.enemies
        elseif class == "AISpawner" then
            return pc.spawners
        elseif class == "HitreactComponent" then
            return pc.hitComps
        elseif class == "FactionComponent" then
            return pc.factions
        elseif class == "PBZPickupActor" then
            local alive = {}
            for _, p in ipairs(pc.pickups) do
                if rawget(p, "__alive") then
                    alive[#alive + 1] = p
                end
            end
            return alive
        elseif class == "BP_Chest_C" then
            return pc.chests
        elseif class == "BP_KickStone_C" then
            return pc.stones or {}
        elseif class == "BP_FogDoor_C" then
            return pc.fogWalls or {}
        elseif class == "WB_MapNew_C" then
            return { mapScreen }
        elseif class == "PBZInteractComponent" then
            return pc.interactComps
        elseif class == "PBZSwitchBase" then
            return pc.switches
        elseif class == "W_BellMenu_C" then
            return pc.bellMenus
        elseif class == "CommonActivatableWidget" then
            return pc.screens
        elseif class == "InputAction" then
            return pc.inputActions
        elseif class == "InputMappingContext" then
            return pc.inputContexts
        elseif class == "EnhancedInputLocalPlayerSubsystem" then
            return pc.inputSubsystems
        elseif class == "OptimizationProxyComponent" then
            return pc.proxies
        elseif class == "PBZFlowInteractActorBase" then
            return pc.flows
        end
        return nil
    end
    env.FName = function(text)
        return setmetatable({ TagName = nil }, { __index = { ToString = function() return text end } })
    end
    env.FText = function(text) return text end
    env.LoadAsset = function() end
    env.ExecuteInGameThread = function(fn) fn() end
    env.RegisterKeyBind = function() end
    env.Key = {}
    env.RegisterHook = function(path, fn, after)
        pc.hooks[path] = pc.hooks[path] or {}
        table.insert(pc.hooks[path], fn)
        pc.afterHooks[path] = pc.afterHooks[path] or {}
        table.insert(pc.afterHooks[path], after)
    end
    pc.loadMapHooks = {}
    env.RegisterLoadMapPreHook = function(fn) pc.loadMapHooks[#pc.loadMapHooks + 1] = fn end
    env.LoopInGameThreadWithDelay = function(ms, fn)
        pc.loops[#pc.loops + 1] = { every = ms / 1000, at = pc.now + ms / 1000, fn = fn }
    end
    env.os = setmetatable({ clock = function() return pc.now end, time = function() return 1800000000 + math.floor(pc.now) end,
        getenv = function() return nil end, remove = nil, rename = nil }, { __index = os })
    local fs = files(pc)
    env.os.remove, env.os.rename = fs.remove, fs.rename
    env.io = setmetatable({ open = fs.open }, { __index = io })
    env.package = { loadlib = function(_, entry)
        return link[entry:gsub("^pp_", "")]
    end }
    env.dofile = function(path)
        local f = assert(io.open(path, "rb"))
        local text = f:read("a")
        f:close()
        return assert(load(text, "@" .. path, "t", env))()
    end
    return pc
end

function Fake.start(pc)
    pc.env.dofile(pc.scripts .. "/main.lua")
end

-- One frame of the game.
function Fake.frame(pc, dt)
    pc.now = pc.now + dt
    for _, loop in ipairs(pc.loops) do
        if pc.now >= loop.at then
            loop.at = pc.now + loop.every
            loop.fn()
        end
    end
    Fake.thinkEnemies(pc)
end

Fake.put = put
Fake.list = list
return Fake
