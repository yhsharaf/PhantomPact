-- Local co-op (Role = Local): a second player on this PC, split screen, one copy of the game. Both Souls are in the
-- same world, so nothing goes over the network. Player 2 is a copy of player 1's Soul with its own controller and
-- camera; the game's own input setup runs when the controller possesses it.

return function(api)
    local log, valid, getPlayer1, distance = api.log, api.valid, api.getPlayer1, api.distance
    local game, state = api.game, api.state

    local TICK_MS = 1000
    local RESPAWN_S = 6             -- player 2 comes back beside player 1 this long after going down
    local DOWN_HP = 1
    local FALL_S = 6
    local MOVE_FALLING = 3
    local AWAY_CM = 2000            -- closer to player 1 than this, the game's own triggers around player 1 do the waking
    local WAKE_CM = 6000            -- how far around player 2 spawners wake
    local WAKE_EVERY_S = 3
    local SPLIT_TOP_BOTTOM, SPLIT_LEFT_RIGHT = 0, 1
    local SHOULDER_CM = 81          -- how far the game's camera sits to the Soul's side
    local CENTRE_SPEED = 10
    local BESIDE_CM = 200
    local FALLBACK_HP = 850
    local WATCH_MS = 100            -- how often the joysticks and menus are looked at (a menu closing must hand the pads back fast)
    local BUTTON_MS = 16            -- every frame: player 2's press must feel as quick as player 1's binding
    local CLIMB_CM = 800            -- the distance the game itself shows a climb prompt from
    local MENU_ACTION = "/Game/PBZContent/Input/InputActions/IA_PushGameSystemMenu.IA_PushGameSystemMenu"
    local OFFSET_SETTING_AT = 93    -- bOffsetPlayerGamepadIds in GameMapsSettings
    local ALL_TO_PLAYER_1 = 0       -- no joystick is device 3 - 0, so pad_route.hpp moves none
    local CLAIM_S = 1.0            -- a button held this long on a free joystick claims a waiting player or joins
    local SCENE_REGROUP_CM = 3000
    local FOG_CM = 1000             -- how close to a fog wall the interact button works
    local FOG_APART_CM = 1500
    local BAR_MS = 100
    local BAR_Z = 397
    local BAR_SHOW_S = 8            -- how long the bar stays after a change, at full health
    local BAR_LEFT, BAR_TOP = 0.272, 0.88     -- in the view, matching the game's bar for player 1
    local BAR_WIDTH = 0.092         -- of the screen's width
    local BAR_LOW = 0.3
    local BAR_SILVER = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    local BAR_RED = { R = 0.85, G = 0.12, B = 0.09, A = 1.0 }

    local on = false
    local config = {}
    local configApplied = false
    local routeArmed = false
    local optionsHeld, climbHeld, useHeld = false, false, false
    local menuOpen = false
    local applyConfig               -- defined below, used by tick
    local downSince = nil
    local p2DownSince = nil
    local V = {}                    -- state and settings in one table (Lua allows 200 locals per function)
    local fallingSince = nil
    local nextWake = 0
    local woken = {}
    local usedSwitches = {}         -- actor address -> true once player 2 opened it this rest (a rubbish pile paid out on every press otherwise)
    local swapped = false           -- player 1's controller is driving player 2's body for an interaction (see swapBodies)
    local p2Charges = nil           -- player 2's own gourd charges; nil until the gourd has been seen, reset at a rest

    local function bellMenuUp()
        for _, w in ipairs(FindAllOf("W_BellMenu_C") or {}) do
            local ok, vis = pcall(function() return w:IsVisible() end)
            if ok and vis then
                return true
            end
        end
        return false
    end

    -- The game's screens (tutorial and information pages, chapter titles, dialogues, videos, confirmations, loading,
    -- shops) are "activatable" widgets put up for player 1. Any of them that is up and visible, other than the ones
    -- that are always on or that player 2 handles on their own (the loot card, the dust line), counts as a menu: the
    -- screen goes full width, both pads drive it, and player 2 stands still until it closes.
    local ALWAYS_ON_SCREENS = {
        WBP_FlowSubTitle_C = true, W_FrontEndHUDLayout_C = true, W_GameRootContent_C = true,
        W_QTEActivateWidget_C = true, W_TIpsLayer_C = true, W_questupdate_C = true, WB_TaskTips_C = true,
        WB_ItemTips_C = true, W_AbilityMaterialLine_C = true, W_Demo_KeysWidget_C = true, WB_DebugPrint_C = true,
        W_DebugQuest_C = true, W_pickupgear_C = true, W_GetDustEntry_C = true, WB_BlackScreen_C = true,
        WB_BlackScreen_Flow_C = true, WBP_FlowSequencer_C = true,
        W_PlayerDead_C = true,          -- the game's death screen: player 2 going down shows it, player 1 plays on
    }
    V.screenNow, V.screenClass, V.nextScreenCheck = false, nil, 0
    local function screenUp()
        if os.clock() < V.nextScreenCheck then
            return V.screenNow
        end
        V.nextScreenCheck = os.clock() + 0.2
        local up, cls = false, nil
        for _, w in ipairs(FindAllOf("CommonActivatableWidget") or {}) do
            local ok, hit = pcall(function()
                if not (w:IsActivated() and w:IsVisible()) then
                    return nil
                end
                local name = w:GetClass():GetFName():ToString()
                -- Tutorial hint bars (W_TutorialBar_Hint_*) are passive overlays, not pages: they hold nobody.
                return (not ALWAYS_ON_SCREENS[name] and not name:find("^W_TutorialBar_")) and name or nil
            end)
            if ok and hit then
                up, cls = true, hit
                break
            end
        end
        if up ~= V.screenNow then
            log(up and ("Screen up: " .. tostring(cls)) or ("Screen down: " .. tostring(V.screenClass)))
        end
        V.screenNow, V.screenClass = up, cls
        return V.screenNow
    end
    local restHooked, sitHooked = false, false
    local p2Dust = nil
    local paused = false            -- single player: player 2 stays out until a joystick or the panel brings them in
    local waiting = {}              -- player number -> health to hold while their joystick is gone
    local claimHeld = { 0, 0, 0, 0 }
    local inScene = false
    local fogHeld = {}
    local fogTipped = false
    local barFrame, barFill = nil, nil
    local lastHp, barUntil = nil, 0

    -- A long move lands on ground that may not have streamed in yet (the world loads around each player with a
    -- delay): the Soul is held in the air for a moment and set down once the ground is there.
    V.FAR_MOVE_CM = 5000
    V.FAR_MOVE_HOLD_S = 3.0
    V.FAR_MOVE_MAX_S = 20.0
    local function besidePoint(p1, up)
        local q = p1:K2_GetActorLocation()
        local yaw = math.rad(p1:K2_GetActorRotation().Yaw) + math.pi / 2
        return { X = q.X + math.cos(yaw) * BESIDE_CM, Y = q.Y + math.sin(yaw) * BESIDE_CM, Z = q.Z + up }
    end
    local function moveBeside(pawn, p1)
        local far = distance(pawn:K2_GetActorLocation(), p1:K2_GetActorLocation()) > V.FAR_MOVE_CM
        pawn:K2_SetActorLocation(besidePoint(p1, far and 120 or 30), false, {}, true)
        if far then
            pcall(function() pawn.CharacterMovement:SetMovementMode(5, 0) end)
            -- The world streams in around player 1: the Soul is set down once player 1 stands on the ground again
            -- (a far move drops player 1 too), beside wherever player 1 landed, and never before the hold is over.
            local started = os.clock()
            local function tryLand()
                if not valid(pawn) or pawn.CharacterMovement.MovementMode ~= 5 then
                    return
                end
                local mode = valid(p1) and p1.CharacterMovement.MovementMode or 0
                local grounded = mode == 1 or mode == 2
                if grounded or os.clock() - started >= V.FAR_MOVE_MAX_S then
                    if grounded then
                        pawn:K2_SetActorLocation(besidePoint(p1, 60), false, {}, true)
                    end
                    pcall(function() pawn.CharacterMovement:SetMovementMode(1, 0) end)
                else
                    game.after(0.25, tryLand)
                end
            end
            game.after(V.FAR_MOVE_HOLD_S, tryLand)
        end
    end

    -- Player 1 can be moved a long way at once: a bell's fast travel, a door that leads somewhere else, a scene, a
    -- level load. Player 2 goes along whenever player 1 jumps like that and is left far behind.
    V.JUMP_CM = 3000
    V.p1LastAt = nil
    local function followJumps(p1, p2)
        local q = p1:K2_GetActorLocation()
        local last = V.p1LastAt
        V.p1LastAt = q
        if not last or not q.X then
            return
        end
        if distance(last, q) > V.JUMP_CM and distance(q, p2:K2_GetActorLocation()) > V.JUMP_CM
            and not game.isDead(p2) and not p2DownSince then
            log(string.format("Player 1 moved %.0f m at once: player 2 goes along.", distance(last, q) / 100))
            moveBeside(p2, p1)
        end
    end

    local function componentOf(pawn, className)
        for _, c in ipairs(FindAllOf(className) or {}) do
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == pawn:GetAddress() then
                return c
            end
        end
        return nil
    end

    local function inputSubsystemOf(pc)
        if not (valid(pc) and valid(pc.Player)) then
            return nil
        end
        for _, s in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do
            if s:GetOuter().ControllerId == pc.Player.ControllerId then
                return s
            end
        end
        return nil
    end

    -- Player 2's Soul is spawned before it is possessed, so its interaction component never gets the local player
    -- subsystem the game gives player 1's at start. Without it no ladder or ledge registers on player 2 at all.
    local function wireInteract()
        local pawn = state.p2Pawn
        if not valid(pawn) then
            return
        end
        local ic = componentOf(pawn, "PBZInteractComponent")
        if ic and not valid(ic.LocalPlayerSubsystem) then
            local s = inputSubsystemOf(state.p2Controller)
            if s then
                ic.LocalPlayerSubsystem = s
                log("Player 2 can interact: input subsystem wired.")
            end
        end
        -- Its timer looks for things around the Soul and plays their prompts, and those are on the things, for player 1: player 2
        -- walking off made player 1's own prompt shrink to a dot. Player 2's are their own (V.real), and nothing else needs the timer.
        if ic then
            pcall(function() ic:PauseTimer() end)
        end
        -- Their execution points are WidgetComponents of their own, and with no owner those draw in the first player's half.
        if V.pointsFor ~= pawn:GetAddress() then
            V.pointsFor, V.points = pawn:GetAddress(), {}
            pcall(function()
                local player = state.p2Controller.Player
                local execution = pawn:GetExecutionComponent()
                if valid(execution) then
                    execution.ExecutionWidgets:ForEach(function(kind, point)
                        if valid(point:get()) then
                            point:get():SetOwnerPlayer(player)
                            V.points[kind:get():ToString()] = point:get()
                        end
                    end)
                end
            end)
        end
    end

    -- Dust lives on the Soul, and only player 1's is saved: what player 2 earns goes to player 1.
    local function passDust(p1, p2)
        local ok, now = pcall(function() return p2.ConsciousnessDust end)
        now = ok and tonumber(now) or nil
        if now == nil then
            return
        end
        if p2Dust ~= nil and now > p2Dust then
            p1:ChangeDustNumInternal(now - p2Dust)
            log("Player 2's dust: +" .. (now - p2Dust))
        end
        p2Dust = now
    end

    -- Going down, the game's death card in their half of the screen, and back, its getting up off the ground. The real death would
    -- send player 1 to the bell, so only these two parts of it are shown. The card is put together from its own pictures: its widget,
    -- W_PlayerDead, sends "the player" back by itself a few seconds on, even taken away again, and took player 1 487 m in testing.
    V.DEAD_ART = "/Game/PBZContent/UI/InGame/Dead/"
    V.RISE_ABILITY = "/Game/PBZContent/UI/InGame/Dead/GA_PlayerRespawn"
    V.DEATH_PARTS = {       -- picture; height against their half's (nil: all of it); down from the middle, the same way; seconds to come up
        { V.DEAD_ART .. "bg_dead.bg_dead", nil, 0, 0.5 },
        { V.DEAD_ART .. "bg_dead.bg_dead", nil, 0, 2.5, true },        -- (the last: black, going to dark)
        { V.DEAD_ART .. "T_UI_blood_Combine.T_UI_blood_Combine", 1.4, 0.05, 0.9 },
        { "/Game/PBZContent/UI/UINew/testplaceholder/yun.yun", 0.62, -0.25, 0.4 },
        { "/Game/PBZContent/UI/UINew/testplaceholder/ming.ming", 0.62, 0.27, 0.6 },
    }

    function V.dropDeathCard()
        for _, part in ipairs(V.deathCard or {}) do
            if valid(part.widget) then
                pcall(function() part.widget:RemoveFromParent() end)
            end
        end
        V.deathCard = nil
    end

    function V.showDeathCard(pc)
        V.dropDeathCard()
        local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
        local vw, vh = size.X / scale, size.Y / scale
        local x, y, w, h = vw * 0.5, vh * 0.75, vw, vh * 0.5
        if config.layout == "lr" then
            x, y, w, h = vw * 0.75, vh * 0.5, vw * 0.5, vh
        end
        local size = math.min(h, w * 0.55)      -- (what the parts are measured against: a tall half is no reason to spill over the line)
        V.deathCard = {}
        for i, part in ipairs(V.DEATH_PARTS) do
            local picture = V.gameTexture(part[1])
            if picture then
                local partW, partH = w, h
                if part[2] then
                    local okS, wide = pcall(function() return picture:Blueprint_GetSizeX() / picture:Blueprint_GetSizeY() end)
                    partH = size * part[2]
                    partW = partH * (okS and wide > 0 and wide or 1)
                end
                local widget = api.hud.newImage(picture, partW, partH, BAR_Z + 2 + i)
                if widget then
                    widget:SetPositionInViewport({ X = x, Y = y + size * part[3] }, false)
                    widget:SetRenderOpacity(0)
                    if part[5] then
                        pcall(function() widget.Circle:SetColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 1.0 }) end)
                    end
                    V.deathCard[#V.deathCard + 1] = { widget = widget, w = partW, h = partH, fade = part[4] }
                end
            end
        end
        V.deathSince = os.clock()
    end

    function V.drawDeathCard()
        local up = not (paused or inScene or menuOpen or api.panel.open)
        for _, part in ipairs(V.deathCard or {}) do
            pcall(function()
                api.hud.show(part.widget, up)
                api.hud.fit(part.widget, part.w, part.h)
                part.widget:SetRenderOpacity(math.min(1, (os.clock() - V.deathSince) / part.fade))
            end)
        end
    end

    function V.riseUp()
        local path = V.RISE_ABILITY .. ".GA_PlayerRespawn_C"
        local class = StaticFindObject(path)
        if not valid(class) and type(LoadAsset) == "function" then
            pcall(LoadAsset, V.RISE_ABILITY)
            class = StaticFindObject(path)
        end
        local p2 = state.p2Pawn
        if valid(class) and valid(p2) then
            pcall(function()
                local asc = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(p2)
                if valid(asc) then
                    asc:TryActivateAbilityByClass(class, true)
                end
            end)
        end
    end

    local function respawn(p1)
        if valid(state.p2Pawn) then
            passDust(p1, state.p2Pawn)
            state.p2Pawn:K2_DestroyActor()
        end
        state.p2Pawn = nil
        V.real, V.realUp, V.pointsFor, V.points = nil, false, nil, nil
        V.dropDeathCard()
        p2Dust = nil
        V.dropHud()
        api.spawnPawnForPlayer2(p1:GetClass())
        V.watchControls()
        if valid(state.p2Pawn) then
            game.setMinHealth(state.p2Pawn, DOWN_HP)
            wireInteract()
            V.soulAt = os.clock()
        end
        downSince = nil
    end

    -- Adding a local player hands the game's one UI layout entry to the new player, and player 1's menu and map then
    -- have nowhere to open. Point it back at player 1's own layout, before a menu is open on the wrong one.
    local function keepMenusOnPlayer1(pc)
        local manager = FindFirstOf("PBZUIManagerSubsystem")
        if not valid(manager) or not valid(pc.Player) then
            return
        end
        local mine = pc.Player:GetFName():ToString()
        local own
        -- A player who left leaves a layout behind with no owner: calling into an empty object crashes UE4SS, so each
        -- step is checked.
        for _, layout in ipairs(FindAllOf("PrimaryGameLayout") or {}) do
            local owner = valid(layout) and layout:GetOwningLocalPlayer() or nil
            if valid(owner) and owner:GetFName():ToString() == mine then
                own = layout
            end
        end
        if own == nil then
            return
        end
        manager.CurrentPolicy.RootViewportLayouts:ForEach(function(_, entry)
            local info = entry:get()
            if not valid(info.LocalPlayer) or info.LocalPlayer:GetFName():ToString() ~= mine then
                info.LocalPlayer = pc.Player
                info.RootLayout = own
                log("Menus are back on player 1.")
            end
        end)
    end

    -- A rest heals the player and brings the dead back; the same for player 2. The game sees to the body that sat, which is
    -- player 2's when they rang the bell (see swapBodies), so player 1's is seen to here then.
    local function restPlayers()
        p2Charges, V.lentCharge = nil, nil
        local _, p1 = getPlayer1()
        if swapped then
            p1 = state.swapBody1
            if valid(p1) and not game.isDead(p1) then
                local _, maxHp = game.getHealth(p1)
                if maxHp then
                    game.setHealth(p1, maxHp)
                end
            end
        end
        local p2 = state.p2Pawn
        if valid(p2) and not p2DownSince and not game.isDead(p2) then
            pcall(function() p2["Respawn Recover Attributes"](p2) end)      -- (as for player 1: this clears the low health look)
            pcall(function()
                local _, maxHp = game.getHealth(p2)       -- fullHealth is defined further down
                if maxHp then
                    game.setHealth(p2, maxHp)
                end
            end)
            V.hudHealth(p2)
        elseif p2DownSince then
            if valid(p1) then
                p2DownSince = nil
                respawn(p1)
                log("Player 2 is back (rest).")
            end
        end
    end

    -- The game only wakes the enemies around player 1, so a player 2 exploring alone would find an empty world. Wake
    -- the spawners around them too. Each one once: what they kill stays dead, as for player 1.
    local function wakeEnemies(p1, p2)
        if os.clock() < nextWake then
            return
        end
        nextWake = os.clock() + WAKE_EVERY_S
        if not restHooked then
            restHooked = game.hookRest(function()
                woken = {}
                usedSwitches = {}
                restPlayers()
            end)
        end
        if not sitHooked then
            sitHooked = game.hookSit(restPlayers)
        end
        local here = p2:K2_GetActorLocation()
        if distance(here, p1:K2_GetActorLocation()) < AWAY_CM then
            return
        end
        local count = 0
        for _, s in ipairs(FindAllOf("AISpawner") or {}) do
            pcall(function()
                local name = s:GetFName():ToString()
                if not woken[name] and distance(s:K2_GetActorLocation(), here) <= WAKE_CM then
                    woken[name] = true
                    if s:IsShouldToSpawn() and not valid(s.SpawnedAI) then
                        s:ClaimSeqSpawn(false, true, false)
                        count = count + 1
                    end
                end
            end)
        end
        if count > 0 then
            log("Woke " .. count .. " enemies around player 2.")
        end
    end

    -- The game's NPC optimizer measures distance from player 1 only: enemies near a lone player 2 get their meshes
    -- hidden, their movement frozen and their animation stopped, and look like corpses sliding about. Optimization
    -- is switched off for anything near player 2 (its own blade included) and back on once far from player 2.
    V.OPT_NEAR_CM = 8000
    V.OPT_FAR_CM = 10000
    V.unoptimized = {}          -- proxy address -> true while switched off by us
    V.nextOpt = 0
    local function keepEnemiesAlive(p1, p2)
        if os.clock() < V.nextOpt then
            return
        end
        V.nextOpt = os.clock() + 1.0
        local b = p2:K2_GetActorLocation()
        local seen = {}
        for _, proxy in ipairs(FindAllOf("OptimizationProxyComponent") or {}) do
            local ok, owner = pcall(function() return proxy:GetOwner() end)
            if ok and valid(owner) then
                local okL, loc = pcall(function() return owner:K2_GetActorLocation() end)
                if okL and loc.X then
                    local addr = proxy:GetAddress()
                    local d2 = distance(loc, b)
                    seen[addr] = true
                    -- Player 1's camera must not decide what player 2 sees: no culling by camera sight at all.
                    pcall(function()
                        if proxy.IgnoreCameraSight ~= true then
                            proxy.IgnoreCameraSight = true
                        end
                    end)
                    if not V.unoptimized[addr] and d2 <= V.OPT_NEAR_CM then
                        pcall(function() proxy:DisableAllOptimizations() end)
                        V.unoptimized[addr] = true
                    end
                    if V.unoptimized[addr] then
                        -- Switching the optimization off leaves what its far-away wave did: the Soul's enemies
                        -- are set flying (movement mode 5), their movement and controller tick every few
                        -- hundred ms and their animation ticks only for montages. An enemy left like that stands
                        -- frozen, slides instead of walking and never attacks. Put a ground enemy back on its feet.
                        pcall(function()
                            local cm = owner.CharacterMovement
                            if valid(cm) then
                                local land = cm.DefaultLandMovementMode
                                if cm.MovementMode == 5 and land ~= 5 and land ~= 0 then
                                    -- Not while it fights: a fighting enemy may be in the air on purpose.
                                    local fighting = false
                                    pcall(function()
                                        V.aiComps = V.aiComps or {}
                                        local ai = V.aiComps[addr]
                                        if not valid(ai) then
                                            ai = valid(owner.Controller) and componentOf(owner.Controller, "BP_SGameAIComponent_C") or nil
                                            V.aiComps[addr] = ai
                                        end
                                        if valid(ai) then
                                            fighting = ai.CurrentStateTag.TagName:ToString():find("Combat") ~= nil
                                        end
                                    end)
                                    if not fighting then
                                        cm:SetMovementMode(land, 0)
                                    end
                                end
                                if cm:GetComponentTickInterval() > 0 then
                                    cm:SetComponentTickInterval(0)
                                end
                            end
                            local ctl = owner.Controller
                            if valid(ctl) and ctl:GetActorTickInterval() > 0 then
                                ctl:SetActorTickInterval(0)
                            end
                            local mesh = owner.Mesh
                            if valid(mesh) then
                                if mesh.VisibilityBasedAnimTickOption == 4 then
                                    mesh.VisibilityBasedAnimTickOption = 1
                                end
                                if not mesh:IsVisible() then
                                    mesh:SetVisibility(true, false)
                                end
                                -- Swords hit the mesh, and the far-away wave turns its collision off: enemies hit player
                                -- 2, but its blade goes through them. Not on the dead: they fall as the game set them.
                                if mesh:GetCollisionEnabled() == 0 and not game.isDead(owner) then
                                    mesh:SetCollisionProfileName(FName("Profile_CharacterMesh"), true)
                                    mesh:SetCollisionEnabled(3)
                                end
                            end
                        end)
                    end
                    if V.unoptimized[addr] and d2 > V.OPT_FAR_CM then
                        pcall(function() proxy:EnableOptimizations() end)
                        V.unoptimized[addr] = nil
                    end
                end
            end
        end
        for addr in pairs(V.unoptimized) do
            if not seen[addr] then
                V.unoptimized[addr] = nil
            end
        end
    end

    -- An enemy only closes in on a target that its fight area (the game's "mob domain") lists as inside, and the area
    -- triggers enter player 1 alone: a lone player 2 was V.noticed, even hated, and never attacked. Player 2 is entered
    -- into the area of any live enemy within V.DOMAIN_IN_CM by the area's own enter event, and taken out again once no
    -- enemy of that area is within V.DOMAIN_OUT_CM, or when player 2 goes down.
    V.DOMAIN_IN_CM = 3000
    V.DOMAIN_OUT_CM = 6000
    V.inDomains = {}            -- domain address -> domain, while player 2 is entered by us
    V.nextDomain = 0
    local function domainMembers(d, p2, p1)
        local listed, nearest = 0, nil
        local here = p2:K2_GetActorLocation()
        pcall(function()
            d.ActorsInMobDomain:ForEach(function(_, el)
                local a = el:get()
                if valid(a) then
                    if a:GetAddress() == p2:GetAddress() then
                        listed = listed + 1
                    elseif not (valid(p1) and a:GetAddress() == p1:GetAddress()) and not game.isDead(a) then
                        local okL, loc = pcall(function() return a:K2_GetActorLocation() end)
                        if okL and loc.X then
                            local dist = distance(loc, here)
                            if nearest == nil or dist < nearest then
                                nearest = dist
                            end
                        end
                    end
                end
            end)
        end)
        return listed, nearest
    end
    local function leaveDomains(p2)
        for addr, d in pairs(V.inDomains) do
            if valid(d) and valid(p2) then
                local listed = domainMembers(d, p2)
                for _ = 1, math.min(listed, 3) do
                    pcall(function() d:OnTriggerExitedEvent(p2) end)
                end
            end
            V.inDomains[addr] = nil
        end
    end
    -- Every enemy also runs the game's "disable combat AI until the player enters the domain" script, and the player
    -- it waits for is player 1: with player 2 alone in the area an enemy sees, touches and even lists player 2, and
    -- never starts a search. Each enemy of an area player 2 is in gets that script's enter event with player 1 named
    -- as the one who came in (the per-enemy event, not the area's, so nothing else changes), once in a while so the
    -- ones that spawn later get it too. From then on their own eyes and hatred work on player 2 as on player 1.
    V.ARM_EVERY_S = 10.0
    V.armed = {}                -- enemy address -> os.clock() of the last enter event
    local function armCombatAI(d, p1, p2)
        if not valid(p1) then
            return
        end
        local now = os.clock()
        pcall(function()
            d.ActorsInMobDomain:ForEach(function(_, el)
                local a = el:get()
                if valid(a) and a:GetAddress() ~= p1:GetAddress() and a:GetAddress() ~= p2:GetAddress()
                    and not game.isDead(a) then
                    local addr = a:GetAddress()
                    if not V.armed[addr] or now - V.armed[addr] >= V.ARM_EVERY_S then
                        V.armed[addr] = now
                        local ai = valid(a.Controller) and componentOf(a.Controller, "BP_SGameAIComponent_C") or nil
                        if ai then
                            pcall(function() ai:OnActorEnterDomain(p1) end)
                        end
                    end
                end
            end)
        end)
    end
    local function keepDomains(p1, p2)
        if os.clock() < V.nextDomain then
            return
        end
        V.nextDomain = os.clock() + 0.5
        for _, d in ipairs(FindAllOf("BP_MobDomain_C") or {}) do
            local addr = d:GetAddress()
            local listed, nearest = domainMembers(d, p2, p1)
            if nearest and nearest <= V.DOMAIN_IN_CM and listed == 0
                and (not V.domainFailAt or not V.domainFailAt[addr] or os.clock() - V.domainFailAt[addr] > 10) then
                local ok, err = pcall(function() d:OnTriggerEnteredEvent(p2) end)
                if ok then
                    V.inDomains[addr] = d
                    log(string.format("Player 2 enters a fight area (enemy %.0f cm away).", nearest))
                else
                    V.domainFailAt = V.domainFailAt or {}
                    V.domainFailAt[addr] = os.clock()
                    log("Fight area enter failed: " .. tostring(err))
                end
            end
            if listed > 0 and nearest and nearest <= V.DOMAIN_OUT_CM then
                armCombatAI(d, p1, p2)
            end
            if listed > 0 and V.inDomains[addr] and (nearest == nil or nearest > V.DOMAIN_OUT_CM) then
                for _ = 1, math.min(listed, 3) do
                    pcall(function() d:OnTriggerExitedEvent(p2) end)
                end
                V.inDomains[addr] = nil
                log("Player 2 leaves a fight area.")
            end
        end
    end

    -- The enemies' eyes work for player 1: a Soul walking up to an idle enemy is V.noticed, hated and fought. Player 2
    -- walking up alone mostly isn't (one in three enemies reacted in testing, the rest stood idle with player 2 in
    -- their face). So player 2 is pointed out to an idle enemy the way the game's own area trigger does it: in its
    -- face within V.NOTICE_FRONT_CM for a moment, or right behind it within V.NOTICE_BACK_CM. The enemy's own check
    -- decides whether it may hate player 2 at all (a resetting or scripted enemy says no, as it does for player 1).
    V.NOTICE_FRONT_CM = 1000
    V.NOTICE_BACK_CM = 300
    V.NOTICE_HOLD_S = 1.0
    V.noticed = {}              -- enemy address -> os.clock() of the last notice
    V.inFace = {}               -- enemy address -> os.clock() since player 2 has been in its face
    V.nextNotice = 0
    V.pointers = {}             -- enemy address -> the HUD that points at it

    -- The HUD's arrow to an enemy after you and out of view. The game feeds player 1's.
    function V.pointAt(e, addr, on)
        local hud = on and V.hudFor or nil
        if V.pointers[addr] ~= hud and valid(V.hud) then
            V.pointers[addr] = hud
            pcall(function()
                if on then
                    V.hud:ShowEnemyIndicator(e)
                else
                    V.hud:RemoveEnemyIndicator(e)
                end
            end)
        end
    end

    local function noticePlayer2(p1, p2)
        if os.clock() < V.nextNotice then
            return
        end
        V.nextNotice = os.clock() + 0.25
        local here = p2:K2_GetActorLocation()
        local now = os.clock()
        for _, e in ipairs(game.listEnemies(true)) do
            pcall(function()
                local addr = e:GetAddress()
                if game.isDead(e) or (game.getHealth(e) or 0) <= 0 then
                    V.pointAt(e, addr, false)
                    return
                end
                local q = e:K2_GetActorLocation()
                if not q.X or (q.X == 0 and q.Y == 0) then
                    return
                end
                local d = distance(q, here)
                if d > V.NOTICE_FRONT_CM then
                    V.inFace[addr] = nil
                    V.pointAt(e, addr, false)
                    return
                end
                local hm = e.BP_PBZHatredManagerComponent
                if not valid(hm) then
                    return
                end
                local hates = false
                hm.HatredList:ForEach(function(_, el)
                    local a = el:get()
                    if valid(a) and a:GetAddress() == p2:GetAddress() then
                        hates = true
                    end
                end)
                V.pointAt(e, addr, hates)
                if hates then
                    V.inFace[addr] = nil
                    return
                end
                -- In its face: in front of it (within 70 degrees of where it looks) and close.
                local f = e:GetActorForwardVector()
                local dx, dy = here.X - q.X, here.Y - q.Y
                local len = math.sqrt(dx * dx + dy * dy)
                local dot = len > 1 and ((dx * f.X + dy * f.Y) / len) or 1
                local front = dot >= 0.35
                if front then
                    V.inFace[addr] = V.inFace[addr] or now
                else
                    V.inFace[addr] = nil
                end
                local due = (front and now - V.inFace[addr] >= V.NOTICE_HOLD_S) or d <= V.NOTICE_BACK_CM
                if not due or (V.noticed[addr] and now - V.noticed[addr] < 5.0) then
                    return
                end
                V.noticed[addr] = now
                if hm:CheckCanHatredTarget(p2) == false then
                    return
                end
                local ok = {}
                hm:AddActorToHatredList(p2, ok)
                if ok.Succeed then
                    local ai = componentOf(e.Controller, "BP_SGameAIComponent_C")
                    if ai then
                        pcall(function() ai:ForceIntoCombat(p2) end)
                    end
                    log(string.format("%s notices player 2 (%.0f cm).", e:GetClass():GetFName():ToString():gsub("^BP_Monster_", ""):gsub("_C$", ""), d))
                end
            end)
        end
    end

    -- The game's camera sits over the shoulder, with the Soul off to the left. With the screen split each Soul belongs
    -- in the middle of its own view: this shifts the camera back, on top of whatever camera mode is active.
    -- A screen picks its button pictures from how the game thinks that player plays, and the game only hears player 1's
    -- pad: player 2's screen stays on mouse and keyboard and its prompts show the wrong pictures. So it's told, and gets
    -- the same pictures as player 1.
    V.nextPictures = 0
    local function padPictures()
        if config.p2 == "kbm" or os.clock() < V.nextPictures then
            return
        end
        V.nextPictures = os.clock() + 1.0
        local s1, s2 = nil, nil
        for _, s in ipairs(FindAllOf("CommonInputSubsystem") or {}) do
            if s:GetOuter().ControllerId == 0 then s1 = s else s2 = s end
        end
        if not (valid(s1) and valid(s2)) then
            return
        end
        if s2:GetCurrentInputType() ~= 1 then
            s2:SetCurrentInputType(1)       -- ECommonInputType::Gamepad
        end
        local name = s1:GetCurrentGamepadName()
        if s2:GetCurrentGamepadName():ToString() ~= name:ToString() then
            s2:SetGamepadInputType(name)
        end
    end

    local function centreCamera(pawn)
        pcall(function() pawn.NBCamera:SetAdditiveSocketOffset({ X = 0, Y = -SHOULDER_CM, Z = 0 }, CENTRE_SPEED) end)
    end

    local function nearFog(pawn)
        local here = pawn:K2_GetActorLocation()
        for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            local ok, at = pcall(function() return door:K2_GetActorLocation() end)
            if ok and at.X and distance(at, here) <= FOG_CM then
                return true
            end
        end
        return false
    end

    local function interactPressed(controller)
        return controller:IsInputKeyDown({ KeyName = FName("Gamepad_FaceButton_Right") })
            or controller:IsInputKeyDown({ KeyName = FName("E") })
    end

    -- A boss's fog wall, Souls style: whoever is left outside walks up to it and presses interact to join the fight. The
    -- walls aren't interactive objects, and only player 1 can use those anyway, so this is the mod's own. Tip from tick.
    local function followFog(p1)
        local c1, c2, p2 = getPlayer1(), state.p2Controller, state.p2Pawn
        if paused or not (game.bossFightActive() and valid(c2) and valid(p2)) then
            return
        end
        for n, who in ipairs({ { p1, p2, c1 }, { p2, p1, c2 } }) do
            local pawn, other, controller = who[1], who[2], who[3]
            local pressed = interactPressed(controller)
            if pressed and not fogHeld[n] and not game.isDead(pawn) and not game.isDead(other)
                and distance(pawn:K2_GetActorLocation(), other:K2_GetActorLocation()) > FOG_APART_CM and nearFog(pawn) then
                log(string.format("Player %d went through the fog.", n))
                moveBeside(pawn, other)
            end
            fogHeld[n] = pressed
        end
    end

    local function fogTip(p1, p2)
        if not (game.bossFightActive() and valid(p2)) then
            fogTipped = false
            return
        end
        local apart = distance(p1:K2_GetActorLocation(), p2:K2_GetActorLocation()) > FOG_APART_CM
        if apart and not fogTipped and (nearFog(p1) or nearFog(p2)) then
            fogTipped = true
            api.status.notify("localcoop", "press interact at the fog, or wait there a moment, to join the fight.")
        end
    end

    -- A fight's fog walls close around whoever started it. Player 2, left outside, walks up to the fog and is set
    -- down beside player 1 after a few seconds there without getting any closer (the interact button does it at
    -- once, see followFog). The walls themselves are the game's: what blocks at the fog line is level collision,
    -- not something the mod can open for one player. Fights are a boss, or a fight area player 1 is listed in with
    -- enemies still up.
    V.FOG_JOIN_CM = 1500        -- how close to a fog wall player 2 has to stand
    V.FOG_JOIN_S = 4.0          -- for how long, without coming closer to player 1
    V.fogWait = nil             -- { since, apart } while player 2 stands at the fog
    V.fogJoinedAt = 0
    local function p1InFight(p1, p2)
        if game.bossFightActive() then
            return true
        end
        local here = p1:K2_GetActorLocation()
        for _, d in ipairs(FindAllOf("BP_MobDomain_C") or {}) do
            local ok, at = pcall(function() return d:K2_GetActorLocation() end)
            if ok and at.X and distance(at, here) <= 8000 then
                local listed, nearest = domainMembers(d, p1, p2)      -- player 2 is no enemy of player 1
                if listed > 0 and nearest ~= nil then
                    return true
                end
            end
        end
        return false
    end
    local function joinThroughFog(p1, p2)
        if os.clock() < (V.nextFogJoin or 0) then
            return
        end
        V.nextFogJoin = os.clock() + 0.5
        local waiting = false
        local apart = 0
        if valid(p2) and not game.isDead(p2) and not p2DownSince and not swapped and not inScene then
            apart = distance(p1:K2_GetActorLocation(), p2:K2_GetActorLocation())
            if apart > FOG_APART_CM and p1InFight(p1, p2) then
                local at2 = p2:K2_GetActorLocation()
                for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
                    local ok, at = pcall(function() return door:K2_GetActorLocation() end)
                    if ok and at.X and distance(at, at2) <= V.FOG_JOIN_CM then
                        waiting = true
                        break
                    end
                end
            end
        end
        if not waiting then
            V.fogWait = nil
            return
        end
        local w = V.fogWait
        if not w or apart < w.apart - 150 then
            V.fogWait = { since = os.clock(), apart = apart }      -- new, or still getting closer on its own
            return
        end
        if os.clock() - w.since >= V.FOG_JOIN_S and os.clock() - V.fogJoinedAt > 10.0 then
            V.fogJoinedAt = os.clock()
            V.fogWait = nil
            log("Player 2 joins the fight through the fog.")
            moveBeside(p2, p1)
        end
    end

    local function hideBar()
        api.hud.show(barFrame, false)
        api.hud.show(barFill, false)
    end

    -- The boss health bar is part of player 1's HUD. Player 2 gets a copy at the top of their view for as long as the
    -- fight lasts, and the boss gets the same wake-up for player 2 as any other enemy (it is rarely listed in a fight
    -- area), so a boss woken by player 1 turns on player 2 too.
    V.BOSS_BAR_W, V.BOSS_BAR_H = 420, 14
    V.bossFrame, V.bossFill = nil, nil
    V.bossArmed = {}            -- boss address -> os.clock() of the last wake-up for player 2
    local function hideBossBar()
        if V.bossFrame then
            api.hud.show(V.bossFrame, false)
            api.hud.show(V.bossFill, false)
        end
    end
    local function updateBossBar(pc)
        local p2 = state.p2Pawn
        local bossesNow = game.bossActors and game.bossActors() or {}
        local boss = bossesNow[1]
        if valid(V.hud) then
            hideBossBar()
            V.hudBossBars(bossesNow)
            return
        end
        if paused or inScene or menuOpen or api.panel.open or not (valid(pc) and valid(p2) and valid(boss)) then
            hideBossBar()
            return
        end
        local hp, maxHp = game.getHealth(boss)
        if not (hp and maxHp and maxHp > 0) then
            hideBossBar()
            return
        end
        V.bossFrame = valid(V.bossFrame) and V.bossFrame or api.hud.newImage("panel/bar_frame.png", V.BOSS_BAR_W, V.BOSS_BAR_H, BAR_Z)
        V.bossFill = valid(V.bossFill) and V.bossFill or api.hud.newImage("panel/bar_fill.png", V.BOSS_BAR_W - 4, V.BOSS_BAR_H - 4, BAR_Z + 1)
        if not (V.bossFrame and V.bossFill) then
            return
        end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
        local vw, vh = size.X / scale, size.Y / scale
        local x, y = vw * 0.5, vh * 0.56
        if config.layout == "lr" then
            x, y = vw * 0.75, vh * 0.09
        end
        local frac = math.max(0, math.min(1, hp / maxHp))
        local fillW = math.max(1, math.floor((V.BOSS_BAR_W - 4) * frac))
        V.bossFrame:SetPositionInViewport({ X = x, Y = y }, false)
        pcall(function() V.bossFrame:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)
        api.hud.fit(V.bossFrame, V.BOSS_BAR_W, V.BOSS_BAR_H)
        V.bossFill:SetPositionInViewport({ X = x - (V.BOSS_BAR_W - 4) / 2 + fillW / 2, Y = y }, false)
        api.hud.fit(V.bossFill, fillW, V.BOSS_BAR_H - 4)
        api.hud.show(V.bossFrame, true)
        api.hud.show(V.bossFill, true)
    end
    local function wakeBosses(p1, p2)
        for _, boss in ipairs(game.bossActors and game.bossActors() or {}) do
            local addr = boss:GetAddress()
            local now = os.clock()
            if not V.bossArmed[addr] or now - V.bossArmed[addr] >= 10.0 then
                V.bossArmed[addr] = now
                pcall(function()
                    local ai = valid(boss.Controller) and componentOf(boss.Controller, "BP_SGameAIComponent_C") or nil
                    if ai then
                        ai:OnActorEnterDomain(p1)
                    end
                end)
            end
        end
    end

    -- The game builds one HUD, for player 1. Player 2 gets this bar, placed in their view where player 1's sits in theirs.
    local function updateBar()
        local pc = getPlayer1()
        local p2 = state.p2Pawn
        V.showHud()
        local hudComing = StaticFindObject(V.HUD_CLASS) ~= nil and os.clock() - (V.soulAt or -1e9) < V.HUD_AFTER_S + 1
        if valid(V.hud) or hudComing or paused or inScene or menuOpen or api.panel.open or not (valid(pc) and valid(p2)) or game.isDead(p2) then
            hideBar()
            return
        end
        local hp, max = game.getHealth(p2)
        if not (hp and max and max > 0) then
            return
        end
        local now = os.clock()
        if hp ~= lastHp then
            lastHp, barUntil = hp, now + BAR_SHOW_S
        end
        if hp >= max and now >= barUntil then
            hideBar()
            return
        end
        barFrame = valid(barFrame) and barFrame or api.hud.newImage("panel/bar_frame.png", 300, 16, BAR_Z)
        barFill = valid(barFill) and barFill or api.hud.newImage("panel/bar_fill.png", 296, 12, BAR_Z + 1)
        if not (barFrame and barFill) then
            return
        end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
        local vw, vh = size.X / scale, size.Y / scale
        local left, top = vw * BAR_LEFT, vh * (0.5 + 0.5 * BAR_TOP)
        if config.layout == "lr" then
            left, top = vw * (0.5 + 0.5 * BAR_LEFT), vh * BAR_TOP
        end
        local width, height = vw * BAR_WIDTH, vw * BAR_WIDTH * 16 / 300
        local inner, innerH = width * 296 / 300, height * 12 / 16
        local fill = inner * math.max(0, math.min(1, hp / max))
        barFrame:SetPositionInViewport({ X = left + width / 2, Y = top }, false)
        barFill:SetPositionInViewport({ X = left + (width - inner) / 2 + fill / 2, Y = top }, false)
        api.hud.fit(barFrame, width, height)
        api.hud.fit(barFill, math.max(fill, 1), innerH)
        pcall(function() barFill.Circle:SetColorAndOpacity(hp / max < BAR_LOW and BAR_RED or BAR_SILVER) end)
        api.hud.show(barFrame, true)
        api.hud.show(barFill, true)
    end

    local function fullHealth(pawn)
        local _, max = game.getHealth(pawn)
        return max or FALLBACK_HP
    end

    -- What gear, training and the story add goes on player 1's Soul alone, and a new Soul starts from the base numbers. Of the 223
    -- attributes these differ, the later ones from about halfway through the story. (UltimateCharge does too, but that gauge is each
    -- player's own.) Player 2's base takes what player 1 has now, so a buff of their own stays on top of it.
    local AS_PLAYER1 = { "Health_Max", "Infliction_Max", "BreakDurationAdditionalMultiplier", "Attack", "ShachiAttack", "Shachi_Max" }
    local MATCH_EVERY_S = 2.0
    local nextMatch = 0

    local function matchPlayer1(p1, p2)
        if os.clock() < nextMatch then
            return
        end
        nextMatch = os.clock() + MATCH_EVERY_S
        pcall(function()
            local from, to = p1.AttributeSetBase, p2.AttributeSetBase
            local full = select(1, game.getHealth(p2)) >= to.Health_Max.CurrentValue - 0.5
            if V.firstFor ~= p2:GetAddress() then
                V.firstFor, V.firstNumbers = p2:GetAddress(), {}
            end
            for _, name in ipairs(AS_PLAYER1) do
                local want, have = from[name].CurrentValue, to[name]
                if math.abs(have.BaseValue - want) > 0.01 then
                    V.firstNumbers[name] = V.firstNumbers[name] or have.BaseValue
                    have.CurrentValue = have.CurrentValue + want - have.BaseValue
                    have.BaseValue = want
                elseif V.firstNumbers[name] and math.abs(have.CurrentValue - V.firstNumbers[name]) < 0.01 then
                    have.CurrentValue = want        -- (a buff that ended takes it back to the Soul's first number)
                end
            end
            if full then
                game.setHealth(p2, to.Health_Max.CurrentValue)
            end
        end)
    end

    -- Player 1 down with player 2 still up: the game's own respawn didn't start in testing, so run its recovery steps
    -- by hand and bring player 1 back beside player 2.
    local function revivePlayer1(p1, p2)
        game.setHealth(p1, fullHealth(p1))
        p1["Death Component"]:Respawn()
        p1["Respawn Recover Attributes"](p1)
        p1["Respawn Reset Hit State"](p1)
        p1["Respawn Reset Combat Logic"](p1)
        p1:ResetDeathDissolveOnRespawn()
        p1["Respawn Reset UI"](p1)
        moveBeside(p1, p2)
        log("Player 1 is back.")
    end

    local function tick()
        local pc, p1 = getPlayer1()
        if paused or swapped or not valid(p1) then
            return
        end
        keepMenusOnPlayer1(pc)
        local p2 = state.p2Pawn
        if game.isDead(p1) then
            downSince = downSince or os.clock()
            if os.clock() - downSince >= RESPAWN_S then
                downSince = nil
                if valid(p2) and not game.isDead(p2) then
                    revivePlayer1(p1, p2)
                else
                    log("Both players are down: back to the bell.")
                    game.setHealth(p1, fullHealth(p1))
                    p1:Respawn()
                end
            end
            return
        end
        if not valid(p2) then
            if not (inScene or menuOpen or game.inCutscene() or api.gs():IsGamePaused(pc)) then
                respawn(p1)
            end
            return
        end
        -- CreatePlayer leaves the new controller without ticking, and a controller that doesn't tick reads no input.
        if valid(state.p2Controller) and not state.p2Controller:IsActorTickEnabled() then
            state.p2Controller:SetActorTickEnabled(true)
        end
        wireInteract()
        game.hookMedicine(V.medicineCounted, V.beforeMedicine, V.afterMedicine)
        if not configApplied and not menuOpen then
            configApplied = applyConfig()
            if configApplied and not V.checklistShown then
                -- The two-pad setup in one line, once, when player 2 is in.
                V.checklistShown = true
                local p1Pad, p2Pad = tostring(config.p1 or "joy1"), tostring(config.p2 or "joy2")
                api.status.notify("localcoop", string.format("%s is player 1, %s is player 2. F4: screen and pads. Player 2: Cross climbs and jumps, Circle uses, D-pad down drinks.",
                    p1Pad == "kbm" and "keyboard" or ("pad " .. (p1Pad:match("%d") or "1")),
                    p2Pad == "kbm" and "keyboard" or ("pad " .. (p2Pad:match("%d") or "2"))))
            end
        end
        centreCamera(p1)
        centreCamera(p2)
        pcall(padPictures)
        -- The game's death flow sends "the player" to the bell, and that's player 1 whichever Soul died. So player 2 never
        -- really dies: health stops at DOWN_HP, and that counts as down until they're back beside player 1.
        if not waiting[2] then
            if not inScene then
                game.setMinHealth(p2, DOWN_HP)
            end
        end
        local hp = game.getHealth(p2)
        -- Timers run on the clock, which the pause menu doesn't stop: a Soul spawned while the game is paused never
        -- ticks, hangs in "falling" and is "rescued" for nothing when the menu closes. A scene is the same: the new Soul
        -- would stand in the shot, unhidden. Both wait for the game to run again.
        local held = inScene or api.gs():IsGamePaused(pc)
        passDust(p1, p2)
        if p2DownSince or game.isDead(p2) or (hp and hp <= DOWN_HP) then
            if not p2DownSince then
                p2DownSince = os.clock()
                log("Player 2 is down.")
                leaveDomains(p2)
                pcall(function() p2:DisableInput(state.p2Controller) end)
                pcall(function() p2.Mesh:SetSimulatePhysics(true) end)      -- no real death, so no death animation
                V.showDeathCard(pc)
            end
            if os.clock() - p2DownSince >= RESPAWN_S and not held then
                log("Player 2 is back.")
                p2DownSince = nil
                respawn(p1)
                V.riseUp()
            end
            return
        end
        downSince = nil
        game.guardFormations()
        if not held then
            V.keepHud(pc, p2)
        end
        matchPlayer1(p1, p2)
        wakeEnemies(p1, p2)
        keepEnemiesAlive(p1, p2)
        keepDomains(p1, p2)
        noticePlayer2(p1, p2)
        wakeBosses(p1, p2)
        followJumps(p1, p2)
        fogTip(p1, p2)
        -- Player 2 goes wherever they like. Only a long fall means they dropped out of the world.
        if p2.CharacterMovement.MovementMode == MOVE_FALLING and not held then
            fallingSince = fallingSince or os.clock()
            if os.clock() - fallingSince >= FALL_S then
                log("Player 2 fell out of the world: brought back to player 1.")
                fallingSince = nil
                moveBeside(p2, p1)
            end
        else
            fallingSince = nil
        end
    end

    local localcoop = {}

    local function configPath()
        return api.modDir() .. "localcoop.txt"
    end

    local function loadConfig()
        local f = io.open(configPath(), "r")
        if not f then
            return
        end
        for line in f:lines() do
            local k, v = line:match("^(%w+)=(%w+)$")
            if k == "layout" or k == "p1" or k == "p2" or k == "players" then
                config[k] = v
            end
        end
        f:close()
    end

    local function saveConfig()
        local f = io.open(configPath(), "w")
        if f then
            f:write(string.format("players=%s\nlayout=%s\np1=%s\np2=%s\n", config.players, config.layout, config.p1,
                config.p2))
            f:close()
        end
    end

    local function writeFile(name, text)
        local f = io.open(api.modDir() .. name, "w")
        if f then
            f:write(text)
            f:close()
        end
    end

    -- main.dll's pad_route.hpp: the device named here is player 1's, and the other joystick reaches player 2. It's given
    -- the viewport and the offset setting once, and both live as long as the game.
    local function routePads(device)
        if not routeArmed then
            local viewport = FindFirstOf("GameViewportClient")
            local maps = StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
            if valid(viewport) and valid(maps) then
                writeFile("vp.txt", string.format("%d %d\n", viewport:GetAddress(), maps:GetAddress() + OFFSET_SETTING_AT))
                routeArmed = true
            end
        end
        if device then
            writeFile("pad_stay.txt", device .. "\n")
        else
            os.remove(api.modDir() .. "pad_stay.txt")
        end
    end

    -- Unreal gives the keyboard to ControllerId 0, and the offset setting sends joysticks to ControllerId 1. With two
    -- joysticks the setting stays off and main.dll routes them. Layouts are read by the engine every frame.
    function applyConfig()
        local pc = getPlayer1()
        local p2pc = state.p2Controller
        if not (valid(pc) and valid(p2pc)) then
            return false
        end
        local settings = StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
        settings.TwoPlayerSplitscreenLayout = config.layout == "lr" and SPLIT_LEFT_RIGHT or SPLIT_TOP_BOTTOM
        local keyboard = config.p1 == "kbm" or config.p2 == "kbm"
        api.setGamepadOffset(keyboard)
        routePads(not keyboard and tonumber(config.p1:match("%d")) or nil)
        local gs = api.gs()
        gs:SetPlayerControllerID(pc, config.p2 == "kbm" and 1 or 0)
        gs:SetPlayerControllerID(p2pc, config.p2 == "kbm" and 0 or 1)
        log(string.format("Local co-op: %s, player 1 %s, player 2 %s.", config.layout, config.p1, config.p2))
        return true
    end

    function localcoop.current()
        return { players = tonumber(config.players), layout = config.layout, p1 = config.p1, p2 = config.p2 }
    end

    local function tip(text)
        log(text)
        if api.status and api.status.notify then
            pcall(api.status.notify, "localcoop", text)
        end
    end

    -- Back to one player: full screen, the normal camera, and the game's own controls for player 1.
    local function goSolo()
        if swapped then
            V.unswapBodies()
        end
        local pc, p1 = getPlayer1()
        paused = true
        -- Player 2 stays as a local player, with no Soul and no screen: really removing them makes the game delete the UI
        -- entry player 1's menus and map open through.
        if valid(state.p2Pawn) then
            leaveDomains(state.p2Pawn)
            state.p2Pawn:K2_DestroyActor()
        end
        state.p2Pawn = nil
        V.dropHud()
        V.dropDeathCard()
        V.real, V.realUp, V.pointsFor, V.points = nil, false, nil, nil
        api.gs():SetForceDisableSplitscreen(pc, true)
        waiting, configApplied = {}, false
        p2Dust, p2DownSince, fallingSince = nil, nil, nil
        api.setGamepadOffset(false)
        routePads(nil)
        if valid(pc) then
            api.gs():SetPlayerControllerID(pc, 0)
        end
        if valid(p1) then
            pcall(function() p1.NBCamera:SetAdditiveSocketOffset({ X = 0, Y = 0, Z = 0 }, CENTRE_SPEED) end)
            game.setMinHealth(p1, 0)
        end
        log("Local co-op: single player.")
    end

    local function join()
        paused, configApplied = false, false
        local pc = getPlayer1()
        if valid(pc) then
            api.gs():SetForceDisableSplitscreen(pc, false)
        end
    end

    function localcoop.apply(choice)
        config.players = choice.players
        config.layout, config.p1 = choice.layout, choice.p1
        config.p2 = choice.p2 or config.p2
        saveConfig()
        if choice.players == 1 then
            goSolo()
        elseif paused then
            join()
        else
            applyConfig()
        end
    end

    -- pads.txt from main.dll, one digit per joystick: 0 unplugged, 1 plugged in, 2 a button held. A test on a PC without
    -- joysticks can stand in for them with pads_fake.txt.
    function localcoop.readPads()
        local path = api.modDir() .. "pads.txt"
        local fake = io.open(api.modDir() .. "pads_fake.txt", "r")
        if fake then
            fake:close()
            path = api.modDir() .. "pads_fake.txt"
        end
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local out, i = {}, 0
        for line in f:lines() do
            i = i + 1
            out[i] = tonumber(line:match("%d")) or 0
        end
        f:close()
        return i >= 4 and out or nil
    end

    -- Story scenes play on player 1's camera: both players watch them full screen, and player 2 can't be hurt meanwhile.
    -- Player 2's Soul is hidden for the scene (it's not in the story, and it would stand in the shot) and its pad is
    -- ignored (no steering off a cliff while nobody can see it); both come back the moment the scene ends.
    V.sceneHeld = nil           -- the pawn held for the scene, while held
    local function hiddenWithPlayer2(p2)
        -- The Soul and its weapons (separate actors hung on it; GetAttachedActors gives Lua nothing usable).
        local actors = { p2 }
        for _, w in ipairs(FindAllOf("WeaponActorBase") or {}) do
            pcall(function()
                local owner = w:GetOwner()
                if not valid(owner) then
                    owner = w:GetAttachParentActor()
                end
                if valid(owner) and owner:GetAddress() == p2:GetAddress() then
                    actors[#actors + 1] = w
                end
            end)
        end
        return actors
    end
    local function holdForScene(hold)
        local p2, pc2 = state.p2Pawn, state.p2Controller
        if hold then
            if V.sceneHeld or not valid(p2) then
                return
            end
            V.sceneHeld = p2
            for _, a in ipairs(hiddenWithPlayer2(p2)) do
                pcall(function() a:SetActorHiddenInGame(true) end)
            end
            pcall(function() p2.CharacterMovement:StopMovementImmediately() end)
            if valid(pc2) then
                pcall(function() pc2:SetIgnoreMoveInput(true) pc2:SetIgnoreLookInput(true) end)
            end
        else
            if not V.sceneHeld then
                return
            end
            local held = V.sceneHeld
            V.sceneHeld = nil
            if valid(held) then
                for _, a in ipairs(hiddenWithPlayer2(held)) do
                    pcall(function() a:SetActorHiddenInGame(false) end)
                end
            end
            if valid(pc2) and not swapped and not V.screenHeld then
                pcall(function() pc2:ResetIgnoreInputFlags() end)
            end
        end
    end
    -- While a screen is up, player 2 stands still and pad 2 is ignored (it drives the screen instead).
    V.screenHeld = nil
    local function holdForScreen(hold)
        local p2, pc2 = state.p2Pawn, state.p2Controller
        if hold then
            if V.screenHeld or not valid(p2) then
                return
            end
            V.screenHeld = p2
            pcall(function() p2.CharacterMovement:StopMovementImmediately() end)
            if valid(pc2) then
                pcall(function() pc2:SetIgnoreMoveInput(true) pc2:SetIgnoreLookInput(true) end)
            end
        elseif V.screenHeld then
            V.screenHeld = nil
            if valid(pc2) and not swapped and not V.sceneHeld then
                pcall(function() pc2:ResetIgnoreInputFlags() end)
            end
        end
    end
    local function followScene(pc)
        local p2 = state.p2Pawn
        local playing = game.inCutscene()
        if playing ~= inScene then
            inScene = playing
            api.gs():SetForceDisableSplitscreen(pc, playing or menuOpen)
            if valid(p2) then
                game.setMinHealth(p2, playing and (game.getHealth(p2) or 0) or DOWN_HP)
            end
            holdForScene(playing)
            log(playing and "Scene: full screen." or "Scene over: split screen.")
            -- A scene can move player 1 somewhere new, as the story goes on: player 2 goes along.
            local _, p1 = getPlayer1()
            if not playing and valid(p1) and valid(p2)
                and distance(p1:K2_GetActorLocation(), p2:K2_GetActorLocation()) > SCENE_REGROUP_CM then
                moveBeside(p2, p1)
            end
        end
    end

    local function pawnOf(n, p1)
        return n == 1 and p1 or state.p2Pawn
    end

    local function stopWaiting(n, p1)
        waiting[n] = nil
        if valid(pawnOf(n, p1)) then
            game.setMinHealth(pawnOf(n, p1), n == 2 and DOWN_HP or 0)     -- (a real death of player 2's would take player 1 to the bell)
        end
    end

    -- A free joystick held down: it takes over a player waiting for theirs, else it joins as player 2.
    local function claim(card, p1)
        local n = waiting[1] and 1 or (waiting[2] and 2 or nil)
        if n then
            config["p" .. n] = card
            stopWaiting(n, p1)
            saveConfig()
            applyConfig()
            tip(string.format("player %d is on a new controller.", n))
        elseif paused then
            config.p2, config.players = card, 2
            saveConfig()
            join()
            tip("player 2 joined.")
        end
    end

    -- A player never leaves because a joystick dropped: their Soul stays, can't lose health, and comes back to them
    -- when the joystick returns or another one claims them.
    local function watchPads()
        local pc, p1 = getPlayer1()
        p1 = swapped and state.swapBody1 or p1      -- (in a swap, player 1's controller holds player 2's body)
        if not paused and valid(pc) then
            followScene(pc)
        end
        if api.panel.open or not valid(p1) then
            return
        end
        -- The game's menus are on player 1's screen: while one is up it fills the whole screen, and every joystick goes
        -- there, so both players can use it.
        -- The bell's menu doesn't pause the game but is a menu all the same: both players use it with their own pads.
        local menu = not paused and (api.gs():IsGamePaused(pc) or bellMenuUp() or screenUp())
        if menu ~= menuOpen then
            menuOpen = menu
            api.gs():SetForceDisableSplitscreen(pc, menu or inScene)
            holdForScreen(menu)
            if menu then
                api.setGamepadOffset(false)
                routePads(ALL_TO_PLAYER_1)
            else
                applyConfig()
            end
        end
        -- Nothing of ours holds player 2 any more, yet its controller still ignores the pads (seen once after a
        -- dialogue that ended in a scene): release them. Player 1's controller is the reference: when the game
        -- ignores player 1 too, it's the game's own state and stays.
        local pc2 = state.p2Controller
        if not inScene and not menuOpen and not V.sceneHeld and not V.screenHeld and not swapped and not p2DownSince
            and valid(pc2) and not pc:IsMoveInputIgnored() and pc2:IsMoveInputIgnored() then
            V.p2StuckSince = V.p2StuckSince or os.clock()
            if os.clock() - V.p2StuckSince > 1.0 then
                V.p2StuckSince = nil
                pcall(function() pc2:ResetIgnoreInputFlags() end)
                log("Player 2's pad was left ignored after a scene: released.")
            end
        else
            V.p2StuckSince = nil
        end
        local pads = localcoop.readPads()
        if not pads then
            return
        end
        for n = 1, 2 do
            local pad = tonumber((config["p" .. n] or ""):match("^joy(%d)$"))
            local pawn = pawnOf(n, p1)
            local gone = pad ~= nil and pads[pad] == 0 and (n == 1 or not paused) and valid(pawn)
            if gone and not waiting[n] and not game.isDead(pawn) then
                waiting[n] = game.getHealth(pawn)
                tip(string.format("player %d's controller is disconnected. Reconnect it, or hold a button on another.", n))
            elseif waiting[n] and not gone then
                stopWaiting(n, p1)
                tip(string.format("player %d's controller is back.", n))
            end
            if waiting[n] and valid(pawn) then
                game.setMinHealth(pawn, waiting[n])
            end
        end
        for i = 1, 2 do                 -- (pad_route.hpp moves one of two joysticks: a third would claim a player and reach nobody)
            local card = "joy" .. i
            local free = config.p1 ~= card and (paused or config.p2 ~= card)
            claimHeld[i] = (free and pads[i] == 2) and claimHeld[i] + WATCH_MS / 1000 or 0
            if claimHeld[i] >= CLAIM_S then
                claimHeld[i] = 0
                claim(card, p1)
            end
        end
    end

    localcoop.bellMenuUp, localcoop.screenUp = bellMenuUp, screenUp     -- the online panel keeps out of the game's screens

    -- The controller the keyboard and mouse reach.
    function localcoop.keyboardController()
        local pc = getPlayer1()
        local p2pc = state.p2Controller
        if valid(p2pc) and valid(p2pc.Player) and p2pc.Player.ControllerId == 0 then
            return p2pc
        end
        return pc
    end

    local backpackOf, gourdInfo = game.backpackOf, game.gourdInfo

    -- Chests, piles and bells are written for "player 0": the approach walk, the loot and the rest all act on the
    -- body player 1's controller possesses. So for the length of such an interaction the two controllers swap
    -- bodies: player 1's controller drives player 2's Soul (which then walks, opens and rests as the game intends),
    -- each screen keeps its own camera, and control swaps back when the interaction is over. Player 1 never moves.
    local swapAt, swapIdle = 0, 0
    local swapIsBell, swapSawMenu = false, false
    local SWAP_MAX_S = 120           -- a bell: the player may sit in its menu a while
    local SWAP_BELL_WAIT_S = 20      -- and if that menu hasn't come by now, it isn't coming (hit on the walk, enemies near)
    local SWAP_SWITCH_MAX_S = 10     -- a chest or pile: the walk and the opening take about six seconds
    local SWAP_MONTAGE_S = 6         -- after this, a playing animation no longer holds the swap (hits from enemies never stop)
    local SWAP_IDLE_S = 3.0          -- the bell's walk, ring and menu have gaps between them; swap back only after a real pause

    local function viewOwnBodies(pc1, pc2, b1, b2)
        pcall(function() pc1:SetViewTargetWithBlend(b1, 0, 0, 0, false) end)
        pcall(function() pc2:SetViewTargetWithBlend(b2, 0, 0, 0, false) end)
    end

    local function swapBodies(isBell)
        local pc1, p1 = getPlayer1()
        local pc2, p2 = state.p2Controller, state.p2Pawn
        if swapped or not (valid(pc1) and valid(pc2) and valid(p1) and valid(p2)) then
            return false
        end
        local ok = pcall(function()
            pc1:UnPossess()
            pc2:UnPossess()
            pc1:Possess(p2)
            pc2:Possess(p1)
        end)
        if not ok then
            pcall(function() pc1:Possess(p1) end)
            pcall(function() pc2:Possess(p2) end)
            return false
        end
        viewOwnBodies(pc1, pc2, p1, p2)
        -- Neither pad may steer a body during the swap (pad 2 would be moving player 1's Soul); menus still work.
        -- Controller flags, not the actors' input stacks: those stacks are rebuilt by possession and a stray push
        -- left player 1 unable to move once.
        pcall(function() pc1:SetIgnoreMoveInput(true) pc1:SetIgnoreLookInput(true) end)
        pcall(function() pc2:SetIgnoreMoveInput(true) pc2:SetIgnoreLookInput(true) end)
        state.swapBody1, state.swapBody2 = p1, p2
        swapped, swapAt, swapIdle = true, os.clock(), 0
        swapIsBell, swapSawMenu = isBell == true, false
        return true
    end

    -- A bell clears player 0's control sets, and the game hands them back to whichever controller holds the resting Soul
    -- by then: player 2's, once the bodies are back. Player 1 is left with none and can't move. So for a while after a
    -- swap, player 1 gets what player 2 has.
    local CONTROLS_WATCH_S, CONTROLS_EVERY_S = 10, 0.5
    local controlsUntil, controlsAt = 0, 0

    -- A controller taking a body clears player 0's control sets, any controller: player 2 coming back left player 1 with one set, and
    -- unable to move, for over four seconds. So any new Soul of player 2's starts this watch too.
    function V.watchControls()
        controlsUntil, controlsAt = os.clock() + CONTROLS_WATCH_S, 0
    end

    local function giveControlsBack()
        local now = os.clock()
        if now > controlsUntil or now < controlsAt then
            return
        end
        controlsAt = now + CONTROLS_EVERY_S
        local s1, s2 = inputSubsystemOf((getPlayer1())), inputSubsystemOf(state.p2Controller)
        if not (s1 and s2) then
            return
        end
        local given = 0
        -- (The set a prompt adds goes with the rest as well, with the prompt still up on the bell, and player 1's button dead there.)
        local _, p1 = getPlayer1()
        local ic1 = valid(p1) and p1:GetComponentByClass(StaticFindObject("/Script/ProjectPBZ.PBZInteractComponent")) or nil
        local offered = valid(ic1) and valid(ic1:GetInteractActor())
        for _, c in ipairs(FindAllOf("InputMappingContext") or {}) do
            local found = {}
            if s2:HasMappingContext(c, found) and not s1:HasMappingContext(c, {}) then
                s1:AddMappingContext(c, found.OutFoundPriority or 0, {})
                given = given + 1
            elseif offered and c:GetFName():ToString() == "IMC_Interaction" and not s1:HasMappingContext(c, {}) then
                s1:AddMappingContext(c, 1000, {})
                given = given + 1
            end
        end
        if given > 0 then
            log(string.format("Player 1's controls put back (%d sets).", given))
        end
    end

    -- The game makes one HUD, and everything in it asks for "player 0's" body as it's made: its health and ShaChi bars, gourd,
    -- weapons, buffs. So a second one, made in the moment player 1's controller points at player 2's body, is all player 2's own, in
    -- player 2's half of the screen, and it shows and hides by the same rules as player 1's.
    V.HUD_CLASS = "/Game/PBZContent/UI/FrontEnd/W_FrontEndHUDLayout.W_FrontEndHUDLayout_C"
    V.HUD_AFTER_S = 3.0             -- a new Soul is left to settle this long first
    V.hud, V.hudFor, V.hudUp, V.hudBosses = nil, nil, nil, {}

    -- For one call the game's "player 0's body" is player 2's: the controller points there, with no possession, so nobody's move or
    -- input is touched. (A real swap dropped player 1's input sets, and a Soul back from down can come in the middle of a fight.)
    local function asPlayer1(fn)
        local pc1, p1 = getPlayer1()
        pc1.Pawn = state.p2Pawn
        pc1.Character = state.p2Pawn
        local ok, err = pcall(fn)
        pc1.Pawn = p1
        pc1.Character = p1
        return ok, err
    end

    function V.dropHud()
        if valid(V.hud) then
            pcall(function() V.hud:RemoveFromParent() end)
        end
        for _, bar in pairs(V.hudBosses) do
            if valid(bar) then
                pcall(function() bar:RemoveFromParent() end)
            end
        end
        V.hud, V.hudFor, V.hudUp, V.hudBosses, V.pointers = nil, nil, nil, {}, {}
    end

    function V.keepHud(pc, p2)
        local class = StaticFindObject(V.HUD_CLASS)
        if swapped or not valid(class) or V.hudFor == p2:GetAddress()
            or os.clock() - (V.soulAt or 0) < V.HUD_AFTER_S or api.gs():IsGamePaused(pc) then
            return
        end
        V.dropHud()
        V.hudFor = p2:GetAddress()      -- (so a failure isn't tried every second, for a Soul that may never take it)
        local pc2 = state.p2Controller
        local ok, err = asPlayer1(function()
            local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc2, class, pc2)
            if not valid(w) then
                error("no widget")
            end
            V.hud = w
            w:AddToPlayerScreen(5)
            w:ActivateWidget()
        end)
        log(ok and "Player 2 has a HUD of their own." or ("Player 2's HUD: " .. tostring(err)))
    end

    -- Over a full-width menu or a scene there's no half of the screen for it.
    function V.showHud()
        if not valid(V.hud) then
            return
        end
        local up = not (paused or inScene or menuOpen or swapped or p2DownSince or api.panel.open)
        if up ~= V.hudUp then
            V.hudUp = up
            pcall(function() V.hud:SetVisibility(up and 3 or 1) end)
            for _, bar in pairs(V.hudBosses) do
                pcall(function() bar:SetVisibility(up and 3 or 1) end)
            end
        end
        -- The gourd on it counts the shared one, and theirs is their own.
        if up and p2Charges then
            pcall(function() V.hud.WB_quickslot.BottomMedicineNum:SetText(FText(tostring(p2Charges))) end)
        end
    end

    -- Health written by hand tells nobody, so the bar is told, and comes up as it does for a real change.
    function V.hudHealth(p2)
        local hp, max = game.getHealth(p2)
        if valid(V.hud) and hp and max then
            pcall(function()
                V.hud:ForSeq_UpdatePlayerHP(hp / max)
                V.hud["Need To Show"](V.hud)
            end)
        end
    end

    -- A HUD told of a boss adds a bar to player 1's half whichever HUD is told, and makes nothing in its own. So player 2's bars are
    -- the game's bar made by hand in their half: Init with the boss, and it follows the fight by itself.
    V.BOSS_BAR_CLASS = "/Game/PBZContent/UI/Hud/WB_BossHPBar.WB_BossHPBar_C"
    V.BOSS_BAR_STEP = 90        -- a second boss's bar sits this far under the first

    function V.hudBossBars(bossesNow)
        local fighting = {}
        for i, boss in ipairs(bossesNow) do
            local addr = boss:GetAddress()
            fighting[addr] = true
            local class = StaticFindObject(V.BOSS_BAR_CLASS)
            if not V.hudBosses[addr] and valid(class) then
                local pc2 = state.p2Controller
                local bar = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc2, class, pc2)
                if valid(bar) then
                    V.hudBosses[addr] = bar
                    pcall(function()
                        bar:AddToPlayerScreen(6)
                        bar:Init(boss)
                        bar:SetRenderTranslation({ X = 0, Y = (i - 1) * V.BOSS_BAR_STEP })
                        bar:SetVisibility(V.hudUp == false and 1 or 3)
                    end)
                end
            end
        end
        for addr, bar in pairs(V.hudBosses) do
            if not fighting[addr] then
                V.hudBosses[addr] = nil
                if valid(bar) then
                    pcall(function() bar:RemoveFromParent() end)
                end
            end
        end
    end

    -- The Soul that rested can't guard afterwards: seen after every bell, and gone once it's replaced, as a death does. A
    -- new one takes its place on the spot. A rest heals anyway.
    local RENEW_AFTER_S = 1.0

    local function renewPlayer2()
        local old = state.p2Pawn
        local _, p1 = getPlayer1()
        if swapped or inScene or p2DownSince or not (valid(old) and valid(p1)) then
            return
        end
        local at, facing = old:K2_GetActorLocation(), old:K2_GetActorRotation()
        leaveDomains(old)
        respawn(p1)
        if valid(state.p2Pawn) then
            state.p2Pawn:K2_SetActorLocationAndRotation(at, facing, false, {}, true)
            log("Player 2 is up from the bell.")
        end
    end

    local function unswapBodies()
        local pc1, pc2 = getPlayer1(), state.p2Controller
        local p1, p2 = state.swapBody1, state.swapBody2
        local rested = swapIsBell and swapSawMenu       -- (a ring that never came is no rest)
        swapped = false
        if not (valid(pc1) and valid(pc2) and valid(p1) and valid(p2)) then
            -- Whatever's left goes back to its own controller, or that player can't move.
            for _, pair in ipairs({ { pc1, p1 }, { pc2, p2 } }) do
                local pc, body = pair[1], pair[2]
                if valid(pc) then
                    pcall(function() pc:ResetIgnoreInputFlags() end)
                    if valid(body) then
                        pcall(function()
                            pc:UnPossess()
                            pc:Possess(body)
                        end)
                    end
                end
            end
            return
        end
        pcall(function()
            pc1:UnPossess()
            pc2:UnPossess()
            pc1:Possess(p1)
            pc2:Possess(p2)
        end)
        pcall(function() pc1:ResetIgnoreInputFlags() end)
        pcall(function() pc2:ResetIgnoreInputFlags() end)
        viewOwnBodies(pc1, pc2, p1, p2)
        controlsUntil, controlsAt = os.clock() + CONTROLS_WATCH_S, 0
        log("Player 2's turn is over: controls are back.")
        if rested then
            -- The rest ran on player 2's body. Health written by hand leaves player 1 with the low health look, so it's the bell's step.
            pcall(game.restHere, p1)
            game.after(RENEW_AFTER_S, function()
                local ok, err = pcall(renewPlayer2)
                if not ok then
                    log("Player 2's new Soul: " .. tostring(err))
                end
            end)
        end
    end

    V.unswapBodies = unswapBodies

    -- Called often: swaps back once player 2's body has finished (nothing interacting, no bell menu) or on a timeout.
    local function watchSwap()
        if not swapped then
            pcall(giveControlsBack)
            return
        end
        local body = state.swapBody2
        -- Player 2 went down or lost its Soul mid-interaction: give the bodies back at once.
        if p2DownSince or not valid(body) or game.isDead(body) or state.p2Pawn ~= body then
            unswapBodies()
            return
        end
        local busy = false
        if valid(body) then
            local ic = componentOf(body, "PBZInteractComponent")
            local ok, ing = pcall(function() return ic and ic.InteractingActor end)
            busy = ok and valid(ing)
        end
        local pc1 = getPlayer1()
        local menu = bellMenuUp()
        if menu then
            swapSawMenu = true
        end
        local age = os.clock() - swapAt
        local montage = false
        if age < SWAP_MONTAGE_S then
            pcall(function() montage = api.moves.animOf(body):IsAnyMontagePlaying() end)
        end
        -- The game clears these flags on its own now and then; while swapped no pad may steer a body.
        pcall(function() pc1:SetIgnoreMoveInput(true) pc1:SetIgnoreLookInput(true) end)
        pcall(function() state.p2Controller:SetIgnoreMoveInput(true) state.p2Controller:SetIgnoreLookInput(true) end)
        -- A bell: the walk, the ringing animation and the menu come with quiet gaps between them, so the swap holds
        -- until the menu has been up and gone. Anything else: until nothing is interacting or playing.
        local held = busy or menu or montage or game.inCutscene()
            or (valid(pc1) and api.gs():IsGamePaused(pc1))
            or (valid(body) and body.CharacterMovement.MovementMode ~= 1 and body.CharacterMovement.MovementMode ~= 3)
            or (swapIsBell and not swapSawMenu)
        if held then
            swapIdle = 0
        else
            swapIdle = swapIdle + BAR_MS / 1000
        end
        local limit = SWAP_SWITCH_MAX_S
        if swapIsBell then
            limit = swapSawMenu and SWAP_MAX_S or SWAP_BELL_WAIT_S
        end
        if (swapIdle >= SWAP_IDLE_S and age > 3.0) or (age > limit and not (menu or screenUp())) then
            unswapBodies()
        end
    end

    -- Player 2's interact button, in the order the game itself would take things:
    --   1. A loot card is up (the game draws it on player 1's screen whoever opened the chest): confirm it.
    --   2. A climb spot in reach (ladders, wall runs, ledges): the game's own interaction, with player 2's body.
    --   3. A chest, door or lever in reach: the game's approach walk always moves player 1, so player 2 is put on the
    --      spot the switch asks for, the interaction is started through player 1's component (the only path that hands
    --      out the loot) with player 2 named as the opener, and the walk is finished at once so player 1 stays put.
    --   4. A pickup in reach: the game's pickups only notice player 1, so the item goes into the shared backpack here.
    -- findTarget is the same look-around, used for the prompt on player 2's screen as well.
    local INTERACT_CM = 500          -- the game's own interaction distance (PBZInteractComponent.DistanceB)
    local VOLUME_CM = 500            -- climb spots are big; the interaction itself still decides if it's really in reach
    V.CLOSE_CM = 150              -- right against a climb spot counts as inside it
    local PROMPT_SIZE = 60
    local PROMPT_Y = 0.6             -- down the view, where the game shows player 1's own prompts

    -- How far a point is from an actor: to its bounding box when that box is a sensible size (a ladder, a chest),
    -- else flat distance with some height allowance (a bell's box spans the whole map; its origin hangs 2 m up).
    local function reach(at, actor, maxExtent)
        maxExtent = maxExtent or 600
        local o, e = {}, {}
        local okB = pcall(function() actor:GetActorBounds(false, o, e, false) end)
        if okB and o.X and e.X <= maxExtent and e.Y <= maxExtent and e.Z <= maxExtent * 2 then
            local dx = math.max(0, math.abs(at.X - o.X) - e.X)
            local dy = math.max(0, math.abs(at.Y - o.Y) - e.Y)
            local dz = math.max(0, math.abs(at.Z - o.Z) - e.Z)
            return math.sqrt(dx * dx + dy * dy + dz * dz)
        end
        local okL, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if not (okL and loc.X) then
            return nil
        end
        if math.abs(loc.Z - at.Z) > 350 then
            return 1e9
        end
        local dx, dy = loc.X - at.X, loc.Y - at.Y
        return math.sqrt(dx * dx + dy * dy)
    end

    V.gapBlockerClass = nil
    local function isGapBlocker(v)
        if not valid(V.gapBlockerClass) then
            if V.gapLookupAt and os.clock() < V.gapLookupAt then
                return false
            end
            V.gapLookupAt = os.clock() + 5.0         -- the class loads with the first area that has one
            V.gapBlockerClass = FindObject("BlueprintGeneratedClass", "BP_GameplayBlocker_Base_C")
        end
        local ok, is = pcall(function() return valid(V.gapBlockerClass) and v:IsA(V.gapBlockerClass) end)
        return ok and is == true
    end
    -- Is the player looking at a spot: the flat angle between the camera's direction (the controller's view, as the
    -- game's own prompts use) and the spot, as a cosine. The body's direction stands in without a controller.
    local function facing(pawn, loc, minDot)
        local okF, f = pcall(function()
            local c = pawn.Controller
            if valid(c) then
                local yaw = math.rad(c:GetControlRotation().Yaw)
                return { X = math.cos(yaw), Y = math.sin(yaw) }
            end
            return pawn:GetActorForwardVector()
        end)
        local here = pawn:K2_GetActorLocation()
        if not (okF and f and loc and loc.X) then
            return false
        end
        local dx, dy = loc.X - here.X, loc.Y - here.Y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1 then
            return true
        end
        return (dx * f.X + dy * f.Y) / len >= (minDot or 0.7)
    end
    V.TALK_CM = 400

    -- The game's own rule for this Soul and this thing: in its reach and faced, as player 1 must. Player 2's own interact component
    -- answers it as player 1's does. Without it, a button that's also an execution rang the bell behind them in a fight, and a fog
    -- door or a music trigger counted as something to use.
    function V.gameAllows(pawn, thing)
        local ok, can = pcall(function()
            V.interactClass = V.interactClass or StaticFindObject("/Script/ProjectPBZ.PBZInteractComponent")
            local ic = pawn:GetComponentByClass(V.interactClass)
            return valid(ic) and ic:CanTriggerInteract(thing) and ic:IsPlayerFaceToActor(pawn, thing)
        end)
        if ok and can == true and #game.bossActors() > 0 then
            -- (A bell in a boss fight: the game turns player 1's prompt red and won't have it.)
            local okB, bell = pcall(function() return thing:IsA(StaticFindObject("/Script/ProjectPBZ.PBZCheckPoint")) end)
            return not (okB and bell)
        end
        return ok and can == true
    end

    local function findTarget(pawn, want)
        local bp = backpackOf(pawn)
        if want ~= "climb" and bp and bp.bShowPickItemWidget then
            local okW, card = pcall(function() return bp.ActivePickupWidget:Get() end)
            if okW and valid(card) then
                return "card", card, bp
            end
        end
        local at = pawn:K2_GetActorLocation()
        -- The game's own search for a spot in reach runs for player 1 only, so the nearest climb spot stands in for
        -- it. The component's remembered volume only counts while it's still close: after a ladder it kept pointing
        -- at that ladder from across the map, and every press at a wall run went there instead.
        local volume, bestD = nil, nil
        if want == "use" then
            volume = false
        end
        -- Two families of climb spots: the SpecialMove volumes (ladders, wall and side runs, rappels) and the ASM
        -- ones (poles, slides, rope swings, holes, temporary ladders). Both are the game's own interactables.
        for _, className in ipairs(volume == false and {} or { "SpecialMoveVolumeBase", "BP_ASM_SpVolumeBase_C" }) do
            for _, v in ipairs(FindAllOf(className) or {}) do
                -- To the spot's box, not its origin: a ladder's origin is at its foot, and player 2 may be at the top.
                local d
                -- A gap blocker (the ShaChi hook shot across a gap) is used from a distance, looking at it: the
                -- game shows its prompt from DisplayPointDistance away, and the player stands well below the
                -- grab point. Player 2 looking at one within that range has it as their target, ahead of all else.
                if isGapBlocker(v) then
                    local okL, loc = pcall(function() return v:K2_GetActorLocation() end)
                    local okR, range = pcall(function() return v.DisplayPointDistance end)
                    range = (okR and type(range) == "number" and range > 0) and range or 2500
                    if okL and loc.X and distance(at, loc) <= range and facing(pawn, loc, 0.85) then
                        return "gap", v, bp
                    end
                    d = nil
                else
                    d = reach(at, v, 2500)      -- climb spots are legitimately big (a ladder is 19 m tall)
                end
                if d and d <= VOLUME_CM and (bestD == nil or d < bestD) then
                    -- The game starts a move only for a Soul inside the spot: a press near a wall run from the
                    -- platform above it must stay the plain jump it is for player 1, not a wall run begun from
                    -- the wrong place. Right up against the spot counts too (a ladder's top edge).
                    local okO, inside = pcall(function() return v:IsOverlappingActor(pawn) end)
                    if (okO and inside) or d <= V.CLOSE_CM then
                        volume, bestD = v, d
                    end
                end
            end
        end
        local sm = volume ~= false and componentOf(pawn, "SpecialMoveComponent") or nil
        if sm and valid(sm.CurrentSpecialMoveVolume) then
            local okL, loc = pcall(function() return sm.CurrentSpecialMoveVolume:K2_GetActorLocation() end)
            local okO, inside = pcall(function() return sm.CurrentSpecialMoveVolume:IsOverlappingActor(pawn) end)
            if okL and loc.X and distance(at, loc) <= VOLUME_CM and okO and inside then
                volume = sm.CurrentSpecialMoveVolume
            end
        end
        if volume then
            return "volume", volume, bp
        end
        if want == "climb" then
            return nil
        end
        local best = nil
        bestD = nil
        for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
            local d = reach(at, s)
            if d then
                if d <= INTERACT_CM and (bestD == nil or d < bestD) then
                    local okS, done = pcall(function() return s.CurSwitchState end)
                    if not (okS and done == true) and not usedSwitches[s:GetAddress()] and V.gameAllows(pawn, s) then
                        best, bestD = s, d
                    end
                end
            end
        end
        if best then
            return "switch", best, bp
        end
        -- A person close by. The game only offers one to player 2 now and then, and not at all with player 1 far away, so
        -- its offer isn't waited for: a talk starts from anywhere (see kind "talk").
        local person, personD = nil, V.TALK_CM
        for _, n in ipairs(FindAllOf("BP_NPC_Narrative_C") or {}) do
            local okL, loc = pcall(function() return n:K2_GetActorLocation() end)
            if okL and loc.X and distance(at, loc) < personD and facing(pawn, loc, 0.5) then
                person, personD = n, distance(at, loc)
            end
        end
        if person then
            return "talk", person, bp
        end
        for _, p in ipairs(FindAllOf("PBZPickupActor") or {}) do
            local okL, loc = pcall(function() return p:K2_GetActorLocation() end)
            local okP, pickable = pcall(function() return p.bIsPickable end)
            if okL and loc.X and distance(at, loc) <= INTERACT_CM and (not okP or pickable ~= false) then
                return "pickup", p, bp
            end
        end
        return nil
    end

    local promptTarget, promptTargetKind, promptTargetAt = nil, nil, 0   -- the prompt's last find, reused on a press
    local function interactP2(want)
        local pawn = state.p2Pawn
        if swapped or not valid(pawn) or game.isDead(pawn) or p2DownSince then
            return
        end
        local kind, target, bp
        local fresh = os.clock() - promptTargetAt < 0.4 and valid(promptTarget)
        if fresh and ((want == "climb" and (promptTargetKind == "volume" or promptTargetKind == "gap"))
                or (want == "use" and promptTargetKind ~= "volume" and promptTargetKind ~= "gap")) then
            kind, target, bp = promptTargetKind, promptTarget, backpackOf(pawn)
        else
            kind, target, bp = findTarget(pawn, want)
        end
        if kind == nil then
            return
        end
        local at = pawn:K2_GetActorLocation()
        if kind == "card" then
            -- The loot is already in the backpack by the time the card shows; closing the card is the confirm.
            pcall(function() target:DeactivateWidget() end)
            return
        end
        if kind == "gap" then
            -- The blocker's own interact: it fires the hook shot for the Soul it is given (DoInteract through the
            -- interact component did nothing for player 2 here).
            local ok, err = pcall(function() target:OnInteract(pawn) end)
            log("Player 2 uses " .. target:GetClass():GetFName():ToString() .. (ok and "" or (": " .. tostring(err))))
            return
        end
        if kind == "volume" then
            local ic, volume = componentOf(pawn, "PBZInteractComponent"), target
            if not ic then
                return
            end
            -- A press made out of reach leaves the component "interacting" with nothing happening: clear that first.
            pcall(function() ic:CheckAndForceEndInteract() end)
            local ok, err = pcall(function() ic:DoInteract(volume) end)
            log("Player 2 interacts with " .. volume:GetClass():GetFName():ToString() .. (ok and "" or (": " .. tostring(err))))
            -- Once in testing the climb refused to start on a Soul that had been through a fight, and drawing and
            -- sheathing the weapon put it right. If nothing has begun after a moment (a wall run takes about a second
            -- to start), do that and press once more.
            -- One press should be enough, as for player 1: while nothing has started, press again a few times
            -- quickly, and once more after drawing and sheathing the weapon, which unstuck a Soul once.
            local before = pawn:K2_GetActorLocation()
            local function started()
                return not valid(pawn) or pawn.CharacterMovement.MovementMode == 5
                    or distance(pawn:K2_GetActorLocation(), before) > 60
            end
            for _, delay in ipairs({ 0.2, 0.4, 0.65 }) do
                game.after(delay, function()
                    if not started() and valid(volume) and valid(ic) then
                        pcall(function() ic:CheckAndForceEndInteract() end)
                        pcall(function() ic:DoInteract(volume) end)
                    end
                end)
            end
            game.after(1.5, function()
                if started() then
                    return
                end
                local s, action = inputSubsystemOf(state.p2Controller), nil
                for _, a in ipairs(FindAllOf("InputAction") or {}) do
                    if a:GetFName():ToString() == "IA_ChangeArmed" then action = a end
                end
                if s and action then
                    s:InjectInputVectorForAction(action, { X = 1, Y = 0, Z = 0 }, {}, {})
                end
                game.after(0.8, function()
                    if not started() and valid(volume) and valid(ic) then
                        pcall(function() ic:CheckAndForceEndInteract() end)
                        pcall(function() ic:DoInteract(volume) end)
                        log("Player 2 interacts again.")
                    end
                end)
            end)
            return
        end
        if kind == "talk" then
            -- Player 1's own component starts a talk, as its button does. The dialogue fills both screens anyway, and given to
            -- player 2's component it never opens, with the controllers swapped or not.
            local _, p1 = getPlayer1()
            local ic1 = valid(p1) and componentOf(p1, "PBZInteractComponent") or nil
            if ic1 then
                -- (From afar the game has player 1 walk all the way there first, on their own. The talk fills both screens anyway.)
                if distance(p1:K2_GetActorLocation(), at) > V.TALK_CM then
                    moveBeside(p1, pawn)
                end
                local ok, err = pcall(function()
                    ic1:SetCurrentInteractActor(target)
                    ic1:DoInteract(target)
                end)
                log("Player 2 talks to " .. target:GetClass():GetFName():ToString() .. (ok and "." or (": " .. tostring(err))))
            end
            return
        end
        if kind == "switch" then
            local best = target
            local okC, isBell = pcall(function() return best:IsA(StaticFindObject("/Script/ProjectPBZ.PBZCheckPoint")) end)
            if okC and isBell then
                -- A bell: the game's rest runs on player 2's body through the controller swap (its menu fills the
                -- screen anyway), and watchSwap gives the bodies back once the menu has been and gone.
                if not swapBodies(true) then
                    return
                end
                local ic1 = componentOf(pawn, "PBZInteractComponent")
                if ic1 then
                    pcall(function() ic1:CheckAndForceEndInteract() end)
                    local ok, err = pcall(function() ic1:DoInteract(best) end)
                    log("Player 2 rings the bell" .. (ok and "." or (": " .. tostring(err))))
                else
                    unswapBodies()
                end
                return
            end
            -- A chest or pile, with nobody frozen: player 2 is put on the spot the switch asks for, the interaction
            -- is started through player 1's component (the only path that hands out the loot) with player 2 named as
            -- the opener, and the walk is finished at once so player 1 never moves. Player 2 plays the opening.
            local loc, rot = {}, {}
            local okT = pcall(function() best:GetMoveToTarget(loc, rot, {}, {}, {}, {}) end)
            if okT and loc.X and distance(at, loc) <= INTERACT_CM * 2 then
                pawn:K2_SetActorLocationAndRotation({ X = loc.X, Y = loc.Y, Z = loc.Z + 20 },
                    { Pitch = 0.0, Yaw = rot.Yaw or 0.0, Roll = 0.0 }, false, {}, true)
            end
            local p1 = select(2, getPlayer1())
            local ic1 = valid(p1) and componentOf(p1, "PBZInteractComponent") or nil
            if not ic1 then
                return
            end
            local keep, yaw = p1:K2_GetActorLocation(), p1:K2_GetActorRotation().Yaw
            local spot = best:K2_GetActorLocation()
            local apart = distance(keep, spot)
            local took = nil
            pcall(function() took = ic1:DoInteract(best) end)
            -- (Still busy with the last one it says no, and finishing the walk would then open this one with nothing in it.)
            if took == false then
                return
            end
            pcall(function() best.InteractPlayer = pawn end)
            local ok, err = pcall(function() best:FinishMoveToAsync() end)
            local name = best:GetClass():GetFName():ToString()
            if name == "BP_Rubbish_C" then          -- (a chest says it's open itself, and a lever or a door can be used again)
                usedSwitches[best:GetAddress()] = true
            end
            log("Player 2 opens " .. name .. (ok and "" or (": " .. tostring(err))))
            -- Only the game's walk toward the chest is undone: player 1 running or dodging is player 1's own.
            for _, delay in ipairs({ 0.1, 0.4, 0.9, 1.5 }) do
                game.after(delay, function()
                    if valid(p1) and distance(p1:K2_GetActorLocation(), keep) > 30 and distance(p1:K2_GetActorLocation(), spot) < apart - 30 then
                        p1:K2_SetActorLocationAndRotation(keep, { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false, {}, true)
                    end
                end)
            end
            return
        end
        if kind == "pickup" and bp then
            local p = target
            local okI, id = pcall(function() return p.ItemId:ToString() end)
            if okI and id ~= "" and id ~= "None" then
                local before = game.itemCount(bp, id)
                pcall(function() bp:AddPropsToBackPack(1, FName(id), true) end)
                if game.itemCount(bp, id) <= before then
                    pcall(function() pawn:GiveItem(FName(id), 1) end)
                end
                pcall(function() p:K2_DestroyActor() end)
                log("Player 2 picked up " .. id)
            end
        end
    end

    -- The game draws its "press A" prompt for player 1 only. Player 2 gets this glyph in their own view whenever
    -- their interact button has something to act on, looked up a few times a second.
    -- Player 2's prompt uses the game's own button pictures, in the family the game is showing player 1 (CommonInput's
    -- current gamepad name): PlayStation faces or Xbox letters. The drawn panel pictures stay as the fallback.
    V.GLYPH_ROOT = "/Game/PBZContent/UI/Foundation/Platform/Input/"
    local GLYPHS = {
        ps = { climb = V.GLYPH_ROOT .. "GamepadPS4/V2/Interact/T_Cross_Interact.T_Cross_Interact",
               use = V.GLYPH_ROOT .. "GamepadPS4/V2/Interact/T_Circle_Interact.T_Circle_Interact",
               Execution = V.GLYPH_ROOT .. "GamepadPS4/V2/Interact/T_Circle_Interact.T_Circle_Interact",
               ShachiWeapon = V.GLYPH_ROOT .. "GamepadPS4/V2/Interact/T_R2_Interact.T_R2_Interact",
               SpecialAttack = V.GLYPH_ROOT .. "GamepadPS4/V2/Interact/T_Triangle_Interact.T_Triangle_Interact" },
        xbox = { climb = V.GLYPH_ROOT .. "GamepadXboxOne/Interact/ui_Xbox_A_interact.ui_Xbox_A_interact",
                 use = V.GLYPH_ROOT .. "GamepadXboxOne/Interact/ui_Xbox_B_interact.ui_Xbox_B_interact",
                 Execution = V.GLYPH_ROOT .. "GamepadXboxOne/Interact/ui_Xbox_B_interact.ui_Xbox_B_interact",
                 ShachiWeapon = V.GLYPH_ROOT .. "GamepadXboxOne/Interact/ui_Xbox_RT_interact.ui_Xbox_RT_interact",
                 SpecialAttack = V.GLYPH_ROOT .. "GamepadXboxOne/Interact/ui_Xbox_Y_interact.ui_Xbox_Y_interact" },
        kbm = { climb = V.GLYPH_ROOT .. "KeyboardMouse/New/Interact/ui_PC_key_Space_Interact.ui_PC_key_Space_Interact",
                use = V.GLYPH_ROOT .. "KeyboardMouse/New/Interact/ui_PC_key_E_Interact.ui_PC_key_E_Interact",
                Execution = V.GLYPH_ROOT .. "KeyboardMouse/New/Interact/ui_PC_key_E_Interact.ui_PC_key_E_Interact",
                ShachiWeapon = V.GLYPH_ROOT .. "KeyboardMouse/New/Interact/ui_PC_key_CtrlL_Interact.ui_PC_key_CtrlL_Interact",
                SpecialAttack = V.GLYPH_ROOT .. "KeyboardMouse/New/Interact/ui_PC_key_F_Interact.ui_PC_key_F_Interact" },
    }
    V.glyphTextures = {}
    V.padFamily, V.nextFamily = "xbox", 0
    local function gameTexture(path)
        if valid(V.glyphTextures[path]) then
            return V.glyphTextures[path]
        end
        V.glyphMissAt = V.glyphMissAt or {}
        if V.glyphMissAt[path] and os.clock() < V.glyphMissAt[path] then
            return nil
        end
        local t = StaticFindObject(path)
        if not valid(t) and type(LoadAsset) == "function" then
            pcall(LoadAsset, path)
            t = StaticFindObject(path)
        end
        V.glyphTextures[path] = valid(t) and t or nil
        if not V.glyphTextures[path] then
            V.glyphMissAt[path] = os.clock() + 10.0
        end
        return V.glyphTextures[path]
    end
    V.gameTexture = gameTexture
    local function currentPadFamily(pc)
        if os.clock() < V.nextFamily then
            return V.padFamily
        end
        V.nextFamily = os.clock() + 2.0
        pcall(function()
            local lib = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
            local cls = StaticFindObject("/Script/CommonInput.CommonInputSubsystem")
            local sub = lib:GetLocalPlayerSubSystemFromPlayerController(pc, cls)
            local name = sub:GetCurrentGamepadName():ToString():lower()
            if name:find("ps") or name:find("dual") or name:find("sony") or name:find("playstation") then
                V.padFamily = "ps"
            elseif name ~= "" and name ~= "none" then
                V.padFamily = "xbox"
            end
        end)
        return V.padFamily
    end
    local function glyphFor(pc, kind)
        local path = GLYPHS[config.p2 == "kbm" and "kbm" or currentPadFamily(pc)][kind]
        local t = gameTexture(path)
        if t then
            return path, t
        end
        local key = config.p2 == "kbm" and (kind == "climb" and "panel/prompt_space.png" or "panel/prompt_e.png")
            or (kind == "climb" and "panel/prompt_a.png" or "panel/prompt_b.png")
        return key, key
    end

    -- An execution point looks its button up by player 1's input too, and comes up blank with a keyboard there. Its picture goes in
    -- as the prompt's does, each time it's built.
    function V.pointPictures(pc)
        if V.pointsFor ~= state.p2Pawn:GetAddress() then
            return
        end
        for kind, point in pairs(V.points or {}) do
            local widget = point:GetWidget()
            if valid(widget) and widget:IsVisible() then
                local icon = widget.InputActionWidget.Icon
                if not valid(icon.ResourceObject) then
                    local _, picture = glyphFor(pc, kind)
                    picture = type(picture) == "string" and api.hud.texture(picture) or picture
                    if valid(picture) then
                        icon.ResourceObject = picture
                    end
                end
            end
        end
    end

    local promptWidget, promptTex, promptKind, nextPrompt = nil, nil, nil, 0
    local PROMPT_EVERY_S = 0.15
    local PROMPT_IN_S = 0.18        -- it pops in over this long, as the game's does
    local PROMPT_POP = 1.35         -- from this size
    local PROMPT_BREATH = 0.04      -- and breathes by this much while it's up
    local PROMPT_LIFT_CM = 70       -- above the thing it's for
    V.promptSince = nil             -- when it came up

    -- The game's prompt is a widget on a WidgetComponent of the thing, drawn in the first local player's half of the screen. Player
    -- 2's is that same widget on a component of their own, owned by their local player and set down on the thing: the game's own
    -- look and animations, and the engine holds it to its spot every frame. It's kept on their Soul, and goes with it.
    -- The picture is written in by hand: the widget looks its button up by player 1's input, which may well be a keyboard.
    V.PROMPT_WIDGET = "/Game/PBZContent/UI/InGame/InteractionUI/W_InteractionUI.W_InteractionUI_C"
    V.real, V.realUp = nil, false   -- { comp, widget, body }, and what it's showing: "ring", "button" or false

    function V.realPrompt(pawn)
        local r = V.real
        if r and r.body == pawn:GetAddress() and valid(r.comp) and valid(r.widget) then
            return r
        end
        V.real, V.realUp = nil, false
        local class, compClass = StaticFindObject(V.PROMPT_WIDGET), StaticFindObject("/Script/UMG.WidgetComponent")
        if not (valid(class) and valid(compClass)) then
            return nil
        end
        local pc2 = state.p2Controller
        local ok, comp, widget = pcall(function()
            local c = pawn:AddComponentByClass(compClass, false, { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
            if not valid(c) then
                error("no component")
            end
            c:SetAbsolute(true, true, true)
            c:SetCollisionEnabled(0)
            c:SetWidgetSpace(1)
            c:SetOwnerPlayer(pc2.Player)
            c:SetDrawAtDesiredSize(true)
            c:SetPivot({ X = 0.5, Y = 0.5 })
            local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc2, class, pc2)
            if not valid(w) then
                error("no widget")
            end
            c:SetWidget(w)
            w.InvalidationBox_0:SetCanCache(false)
            c:SetVisibility(false, false)
            return c, w
        end)
        if not (ok and valid(comp) and valid(widget)) then
            log("Player 2's prompt stays the plain one: " .. tostring(comp))
            V.realFailed = true
            return nil
        end
        V.real = { comp = comp, widget = widget, body = pawn:GetAddress() }
        return V.real
    end

    -- at once over a menu or a scene, by its own animation when there's just nothing left to use
    function V.hideRealPrompt(atOnce)
        local r, was = V.real, V.realUp
        V.realUp = false
        if not (r and was and valid(r.comp) and valid(r.widget)) then
            return
        end
        pcall(function()
            if atOnce then
                r.comp:SetVisibility(false, false)
            elseif was == "ring" then
                r.widget:PlayVirtualToNone(r.comp)
            else
                r.widget:PlayInputActionToNone(r.comp)
            end
        end)
    end

    -- ring: the small ring the game shows on a thing not yet in reach, instead of the button.
    function V.showRealPrompt(pawn, spot, picture, ring)
        local r = not V.realFailed and V.realPrompt(pawn) or nil
        if not r then
            return false
        end
        return (pcall(function()
            r.comp:K2_SetWorldLocation(spot, false, {}, false)
            local want = ring and "ring" or "button"
            -- (A fade-out ends by hiding the component, whatever has started since.)
            if V.realUp ~= want or not r.comp:IsVisible() then
                local was = r.comp:IsVisible() and V.realUp
                V.realUp = want
                r.comp:SetVisibility(true, false)
                if ring then
                    if was == "button" then
                        r.widget:PlayInputActionToVirtual(r.comp, false)
                    else
                        r.widget:PlayNoneToVirtualAnimation(r.comp)
                    end
                elseif was == "ring" then
                    r.widget:PlayVirtualToInput(r.comp, false)
                else
                    r.widget:PlayNoneToInputAction(r.comp)
                end
            end
            if ring then
                return
            end
            local icon = r.widget.InputActionWidget_C_75.Icon
            if not valid(icon.ResourceObject) or icon.ResourceObject:GetAddress() ~= picture:GetAddress() then
                icon.ResourceObject = picture
                r.widget.InvalidationBox_0:InvalidateCache()
            end
        end))
    end

    local function hidePrompt(atOnce)
        V.promptSince = nil
        V.hideRealPrompt(atOnce)
        if promptWidget then
            api.hud.show(promptWidget, false)
        end
    end

    -- The nearest thing to use that's in the game's sight but not its reach. (A look a few times a second, and only with nothing in reach.)
    V.RING_CM = 2000
    function V.ringThing(pawn)
        local now = os.clock()
        if now < (V.ringAt or 0) then
            return V.ringWas
        end
        V.ringAt, V.ringWas = now + 0.3, nil
        V.interactClass = V.interactClass or StaticFindObject("/Script/ProjectPBZ.PBZInteractComponent")
        local ic = pawn:GetComponentByClass(V.interactClass)
        if not valid(ic) then
            return nil
        end
        local at, best = pawn:K2_GetActorLocation(), V.RING_CM
        for _, s in ipairs(FindAllOf("PBZSwitchBase") or {}) do
            local d = reach(at, s)
            if d and d < best and not usedSwitches[s:GetAddress()] then
                local ok, near = pcall(function() return s.CurSwitchState ~= true and ic:GetValidDistance(s, pawn) end)
                if ok and near == true then
                    V.ringWas, best = s, d
                end
            end
        end
        return V.ringWas
    end

    -- Where the game shows the thing's own prompt, or over it when it has none. Nil for what has no place in the world (a loot card).
    function V.promptAnchor(target)
        local ok, at = pcall(function()
            local wc = target:GetComponentByClass(StaticFindObject("/Script/UMG.WidgetComponent"))
            if valid(wc) then
                return wc:K2_GetComponentLocation()
            end
            local l = target:K2_GetActorLocation()
            return { X = l.X, Y = l.Y, Z = l.Z + PROMPT_LIFT_CM }
        end)
        return ok and at and at.X and { X = at.X, Y = at.Y, Z = at.Z } or nil
    end

    -- Over what it's for, as player 1's is, while that's inside player 2's own half of the screen (the third answer). Otherwise, or
    -- for what has no place in the world, where the game shows its own.
    local function promptSpot(vw, vh, scale, target)
        local x, y = vw * 0.5, vh * (0.5 + 0.5 * PROMPT_Y)
        local left, top = 0, vh * 0.5
        if config.layout == "lr" then
            x, y = vw * 0.75, vh * PROMPT_Y
            left, top = vw * 0.5, 0
        end
        local at = {}
        local spot = V.promptAnchor(target or promptTarget)
        local ok = spot and pcall(function()
            state.p2Controller:ProjectWorldLocationToScreen(spot, at, false)
        end)
        if ok and at.X and at.Y then
            local ax, ay = at.X / scale, at.Y / scale
            if ax > left + PROMPT_SIZE and ax < vw - PROMPT_SIZE and ay > top + PROMPT_SIZE and ay < vh - PROMPT_SIZE then
                return ax, ay, spot
            end
        end
        return x, y, nil
    end

    -- Every frame while it's up: the look-around is a few times a second, but a picture moved that often jumps as the camera turns.
    local function drawPrompt(pc)
        if not (V.promptSince and valid(promptWidget)) then
            return
        end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
        local x, y = promptSpot(size.X / scale, size.Y / scale, scale)
        promptWidget:SetPositionInViewport({ X = x, Y = y }, false)
        local now = os.clock()
        local t = math.min(1, (now - V.promptSince) / PROMPT_IN_S)
        local ease = 1 - (1 - t) * (1 - t)
        local grow = PROMPT_POP + (1 - PROMPT_POP) * ease + PROMPT_BREATH * math.sin(now * 4) * ease
        api.hud.fit(promptWidget, PROMPT_SIZE * grow, PROMPT_SIZE * grow)
        pcall(function() promptWidget:SetRenderOpacity(ease) end)
    end

    local function updatePrompt()
        local pc = getPlayer1()
        local pawn = state.p2Pawn
        if swapped or paused or inScene or menuOpen or api.panel.open or not (valid(pc) and valid(pawn))
            or game.isDead(pawn) or p2DownSince then
            hidePrompt(true)
            return
        end
        -- (On a rope or a ladder, or in the air, there's nothing to press: the game shows player 1 nothing either.)
        local okM, mode = pcall(function() return pawn.CharacterMovement.MovementMode end)
        if okM and mode ~= 1 and mode ~= 2 then
            hidePrompt()
            return
        end
        local now = os.clock()
        if now >= nextPrompt then
            nextPrompt = now + PROMPT_EVERY_S
            local ok, kind, target = pcall(findTarget, pawn, "use")
            promptKind = ok and kind or nil
            if promptKind == nil then
                ok, kind, target = pcall(findTarget, pawn, "climb")
                promptKind = ok and kind or nil
            end
            promptTarget, promptTargetKind, promptTargetAt = ok and target or nil, promptKind, now
        end
        if promptKind == nil then
            -- Something near, not yet in reach: the game's ring on it, as player 1 has.
            local thing = V.ringThing(pawn)
            local shown = false
            if thing then
                pcall(function()
                    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
                    local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
                    local spot = select(3, promptSpot(size.X / scale, size.Y / scale, scale, thing))
                    shown = spot ~= nil and V.showRealPrompt(pawn, spot, nil, true)
                end)
            end
            V.promptSince = nil
            if promptWidget then
                api.hud.show(promptWidget, false)
            end
            if not shown then
                V.hideRealPrompt()
            end
            return
        end
        local tex, pic = glyphFor(pc, (promptKind == "volume" or promptKind == "gap") and "climb" or "use")
        local spot = nil
        pcall(function()
            local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
            local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
            spot = select(3, promptSpot(size.X / scale, size.Y / scale, scale))
        end)
        local picture = type(pic) == "string" and api.hud.texture(pic) or pic
        if spot and valid(picture) and V.showRealPrompt(pawn, spot, picture) then
            V.promptSince = nil
            if promptWidget then
                api.hud.show(promptWidget, false)
            end
            return
        end
        V.hideRealPrompt()
        if not valid(promptWidget) then
            promptWidget = api.hud.newImage(pic, PROMPT_SIZE, PROMPT_SIZE, BAR_Z + 2)
            promptTex = tex
        elseif promptTex ~= tex then
            -- Swap the picture on the one widget: a new widget shows at its own size for a frame before it is fitted.
            local t = type(pic) == "string" and api.hud.texture(pic) or pic
            if t then
                pcall(function()
                    local img = promptWidget.Circle
                    img:SetBrushFromTexture(t, false)
                    local b = img.Brush
                    b.ImageSize = { X = PROMPT_SIZE, Y = PROMPT_SIZE }
                    img:SetBrush(b)
                end)
                promptTex = tex
            end
        end
        if not promptWidget then
            return
        end
        if not V.promptSince then
            V.promptSince = now
            drawPrompt(pc)
        end
        api.hud.show(promptWidget, true)
    end

    -- The game's menus listen on player 1's screen only, so player 2's Options button does nothing there. It's passed on
    -- as player 1's own menu action.
    -- The gourd and the D-pad's other item work on "the player", which is player 1 whoever drank. The step that applies them looks the
    -- player up as it runs, so for that one call player 1's controller points at player 2's body: the heal, its buffs, its glow and the
    -- HUD's flash are the drinker's, by the game's own hand. (Moved afterwards, player 1 glowed and kept the buffs.)
    local HEAL_WINDOW_S = 6.0        -- a press this old can still be why a drink comes: the gourd is held a moment before it heals
    local function key(name)
        return { KeyName = FName(name) }
    end
    local function itemPressed(controller)
        return controller:IsInputKeyDown(key("Gamepad_DPad_Down")) or controller:IsInputKeyDown(key("Gamepad_DPad_Up"))
    end
    -- Player 2 has gourd charges of its own, as many as the gourd holds, back to full at every bell rest. The game
    -- takes each drink out of the one shared gourd, so that charge is put back and one of player 2's is spent.
    local function refillPlayer2(pawn)
        local info = gourdInfo(pawn)
        if info then
            local okM, max = pcall(function() return info.MaxTime end)
            p2Charges = okM and type(max) == "number" and max or p2Charges
        end
    end
    local function spendPlayer2Charge(pawn)
        local info = gourdInfo(pawn)
        if p2Charges == nil then
            refillPlayer2(pawn)
        end
        if info and not V.lentCharge then
            -- The shared gourd keeps its charge. The game writes the count again as the drink finishes, so the refund
            -- is made now and repeated a little later, never above the gourd's maximum.
            V.gourdKeep = info.CurrentTime + 1
            V.keepSerial = (V.keepSerial or 0) + 1
            local serial = V.keepSerial
            local function refund()
                if not V.gourdKeep or not valid(info) then
                    return                  -- a map change: pcall can't catch touching what it took away
                end
                pcall(function()
                    local max = info.MaxTime
                    local want = math.min(V.gourdKeep, type(max) == "number" and max or V.gourdKeep)
                    if info.CurrentTime < want then
                        info:SetCurrentTime(want)
                        info:SetDisplayTime(want)
                    end
                end)
            end
            refund()
            game.after(1.0, refund)
            game.after(2.5, refund)
            game.after(4.0, function()
                refund()
                if serial == V.keepSerial then
                    V.gourdKeep = nil
                end
            end)
        end
        if p2Charges ~= nil and p2Charges > 0 then
            p2Charges = p2Charges - 1
            return true
        end
        return false
    end
    -- The game asks the shared gourd, and with player 1 having emptied it player 2's own press did nothing at all. So their charge is
    -- lent to it and the press made again, and it's taken back if it wasn't drunk.
    function V.gourdCount(pawn)
        local info = gourdInfo(pawn)
        local ok, n = pcall(function() return info.CurrentTime end)
        return ok and type(n) == "number" and n or nil
    end
    function V.lendCharge(p2, p2pc)
        if p2Charges == 0 or V.gourdCount(p2) ~= 0 or not p2pc:IsInputKeyDown(key("Gamepad_DPad_Down")) then
            return
        end
        if p2Charges == nil then
            refillPlayer2(p2)
        end
        local info, s = gourdInfo(p2), inputSubsystemOf(p2pc)
        local action = nil
        for _, a in ipairs(FindAllOf("InputAction") or {}) do
            if a:GetFName():ToString() == "IA_UseBottomItem" then action = a end
        end
        if p2Charges and p2Charges > 0 and s and action then
            info:SetCurrentTime(1)
            info:SetDisplayTime(1)
            V.lentCharge = true
            s:InjectInputVectorForAction(action, { X = 1, Y = 0, Z = 0 }, {}, {})
        end
    end
    function V.takeChargeBack(p2)
        if V.lentCharge then
            V.lentCharge = nil
            local info = gourdInfo(p2)
            if info and V.gourdCount(p2) == 1 then
                pcall(function()
                    info:SetCurrentTime(0)
                    info:SetDisplayTime(0)
                end)
            end
        end
    end

    function V.drinking(pawn)
        local okA, anim = pcall(function() return pawn.Mesh:GetAnimInstance() end)
        if not (okA and valid(anim)) then
            return false
        end
        local ok, m = pcall(function() return anim:GetCurrentActiveMontage() end)
        if not (ok and valid(m)) then       -- (no montage is an empty object, and calling into one crashes UE4SS)
            return false
        end
        local name = m:GetFName():ToString()
        return name:find("Medicine", 1, true) ~= nil or name:find("Heyao", 1, true) ~= nil
    end
    function V.player2Drinks()
        local p2, p1 = state.p2Pawn, select(2, getPlayer1())
        return not swapped and valid(p2) and valid(p1) and not V.drinking(p1)
            and (V.drinking(p2) or os.clock() - (V.drinkPressAt or -1e9) < HEAL_WINDOW_S)
    end

    -- After the game has counted a drink: only the gourd is counted twice. The D-pad's other item is in the bag for both of them.
    function V.medicineCounted(id)
        local p2 = state.p2Pawn
        local okB, bottom = pcall(function() return backpackOf(p2).BottomMedicineID:ToString() end)
        local gourd = okB and id == bottom
        if not V.player2Drinks() then
            if gourd and V.gourdKeep then
                V.gourdKeep = V.gourdKeep - 1       -- (player 1 drank theirs while one was being put back for player 2)
            end
            return
        end
        V.drinkDry = gourd and not spendPlayer2Charge(p2)
        V.lentCharge = nil
    end

    function V.beforeMedicine()
        if V.player2Drinks() then
            local pc, p1 = getPlayer1()
            V.drinkPc, V.drinkBody, V.drinkHp = pc, p1, game.getHealth(state.p2Pawn)
            pc.Pawn = state.p2Pawn
            pc.Character = state.p2Pawn
        end
    end

    function V.afterMedicine()
        local pc, p1 = V.drinkPc, V.drinkBody
        if not p1 then
            return
        end
        V.drinkPc, V.drinkBody = nil, nil
        pc.Pawn = p1
        pc.Character = p1
        local p2 = state.p2Pawn
        if V.drinkDry then
            game.setHealth(p2, V.drinkHp)
            V.hudHealth(p2)
            tip("player 2's gourd is empty: rest at a bell.")
        else
            log(string.format("Player 2 drinks, %d charge(s) left.", p2Charges or 0))
        end
    end

    local itemHeld = false
    local function watchHeal(pc, p2pc, p1, p2)
        local pressed = itemPressed(p2pc)
        if pressed and not itemHeld and not itemPressed(pc) and not swapped then
            V.drinkPressAt = os.clock()
            pcall(V.lendCharge, p2, p2pc)
        end
        itemHeld = pressed
        V.afterMedicine()       -- (it has always run by now: this is for a call that ended some other way)
        if V.lentCharge and os.clock() - V.drinkPressAt > HEAL_WINDOW_S then
            V.takeChargeBack(p2)
        end
    end

    local function relayButtons()
        local pc = getPlayer1()
        local p2pc = state.p2Controller
        drawPrompt(pc)
        V.drawDeathCard()
        if paused or inScene or menuOpen or api.panel.open or not (valid(pc) and valid(p2pc) and valid(pc.Player)) then
            if valid(p2pc) then
                optionsHeld = p2pc:IsInputKeyDown({ KeyName = FName("Gamepad_Special_Right") })
                climbHeld = p2pc:IsInputKeyDown({ KeyName = FName("Gamepad_FaceButton_Bottom") })
                useHeld = p2pc:IsInputKeyDown({ KeyName = FName("Gamepad_FaceButton_Right") })
            end
            return
        end
        local _, p1 = getPlayer1()
        if valid(p1) and valid(state.p2Pawn) and not swapped then
            watchHeal(pc, p2pc, p1, state.p2Pawn)
        end
        local pressed = p2pc:IsInputKeyDown({ KeyName = FName("Gamepad_Special_Right") })
        if pressed and not optionsHeld then
            local action = StaticFindObject(MENU_ACTION)
            for _, s in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do
                if valid(action) and s:GetOuter().ControllerId == pc.Player.ControllerId then
                    s:InjectInputVectorForAction(action, { X = 1, Y = 0, Z = 0 }, {}, {})
                end
            end
        end
        optionsHeld = pressed
        -- As the game binds them for player 1: Cross (Space) starts a climb, Circle (E) interacts with the rest.
        local climb = p2pc:IsInputKeyDown({ KeyName = FName("Gamepad_FaceButton_Bottom") })
            or (config.p2 == "kbm" and p2pc:IsInputKeyDown({ KeyName = FName("SpaceBar") }))
        if climb and not climbHeld then
            interactP2("climb")
        end
        climbHeld = climb
        local use = p2pc:IsInputKeyDown({ KeyName = FName("Gamepad_FaceButton_Right") })
            or (config.p2 == "kbm" and p2pc:IsInputKeyDown({ KeyName = FName("E") }))
        if use and not useHeld then
            interactP2("use")
        end
        useHeld = use
    end

    -- joysticks: 1 = keyboard for player 1, the joystick for player 2. 2 = one joystick for each player. The panel's
    -- last Apply, if there is one, wins.
    function localcoop.start(joysticks)
        if on then
            return
        end
        on = true
        config.players, config.layout = "2", "tb"
        config.p1 = joysticks < 2 and "kbm" or "joy1"
        config.p2 = joysticks < 2 and "joy1" or "joy2"
        loadConfig()
        paused = config.players == "1"
        api.setGamepadOffset(not paused and (config.p1 == "kbm" or config.p2 == "kbm"))
        local watch = io.open(api.modDir() .. "pads_watch.txt", "w")
        if watch then
            watch:write("1\n")
            watch:close()
        end
        api.panel.start()
        log(string.format("Local co-op on: %d joystick(s).", joysticks))
        -- A map change (Return to Title Screen, Load Game, a chapter's level travel) with a second local player still
        -- in leaves the next map without its UI: the title screen came up black in testing. Before the engine loads
        -- the next map, player 2 steps out entirely, as if the game were single player; once the new map is playing,
        -- tick() finds no player 2 and creates them again beside player 1.
        pcall(function()
            RegisterLoadMapPreHook(function()
                local ok, err = pcall(function()
                    local had = valid(state.p2Controller)
                    if valid(state.p2Pawn) then
                        pcall(leaveDomains, state.p2Pawn)
                    end
                    api.removePlayer2()
                    V.dropHud()
                    V.dropDeathCard()
                    V.real, V.realUp, V.pointsFor, V.points = nil, false, nil, nil
                    -- (A swap can't outlive the map: the new one's pawns are the game's, and those bodies are gone. Nor can what's kept of them.)
                    if swapped then
                        swapped, state.swapBody1, state.swapBody2 = false, nil, nil
                        pcall(function() getPlayer1():ResetIgnoreInputFlags() end)
                    end
                    V.lentCharge, V.gourdKeep, V.drinkPc, V.drinkBody = nil, nil, nil, nil
                    promptTarget, promptKind, promptTargetKind, V.promptSince, V.ringWas = nil, nil, nil, nil, nil
                    V.sceneHeld, V.screenHeld, V.p1LastAt = nil, nil, nil
                    inScene, menuOpen = false, false
                    woken, usedSwitches = {}, {}
                    waiting, configApplied = {}, false
                    p2Dust, p2DownSince, fallingSince, downSince = nil, nil, nil, nil
                    if had then
                        log("Map change: player 2 steps out until the new map is up.")
                    end
                end)
                if not ok then
                    log("Map change error: " .. tostring(err))
                end
            end)
        end)
        LoopInGameThreadWithDelay(TICK_MS, function()
            local ok, err = pcall(tick)
            if not ok then
                log("Local co-op error: " .. tostring(err))
            end
            return false
        end)
        LoopInGameThreadWithDelay(BAR_MS, function()
            local ok, err = pcall(function()
                watchSwap()         -- (first: a slip in what's drawn must never leave both pads on each other's bodies)
                updateBar()
                updateBossBar(getPlayer1())
                updatePrompt()
                if valid(state.p2Pawn) then
                    pcall(V.pointPictures, getPlayer1())
                end
                local _, p1 = getPlayer1()
                if valid(p1) then
                    followFog(p1)
                    if not paused and valid(state.p2Pawn) then
                        joinThroughFog(p1, state.p2Pawn)
                    end
                end
            end)
            if not ok then
                log("Local co-op error: " .. tostring(err))
            end
            return false
        end)
        LoopInGameThreadWithDelay(BUTTON_MS, function()
            local ok, err = pcall(relayButtons)
            if not ok then
                log("Button relay error: " .. tostring(err))
                return true
            end
            return false
        end)
        LoopInGameThreadWithDelay(WATCH_MS, function()
            local ok, err = pcall(watchPads)
            if not ok then
                log("Local co-op error: " .. tostring(err))
            end
            return false
        end)
    end

    -- F5: bring player 2 back to player 1 by hand (stuck on a ledge, say).
    function localcoop.regroup()
        local _, p1 = getPlayer1()
        if not swapped and valid(p1) and valid(state.p2Pawn) and not game.isDead(state.p2Pawn) then
            moveBeside(state.p2Pawn, p1)
        end
    end

    function localcoop.command(rest)
        if rest == "on" then
            localcoop.start(2)
            join()
        elseif rest == "off" then
            goSolo()
        elseif rest == "interact" or rest == "use" or rest == "climb" then
            interactP2(rest ~= "interact" and rest or nil)      -- as if player 2 pressed their interact button (tests)
        elseif rest == "scene on" or rest == "scene off" then
            holdForScene(rest == "scene on")        -- the scene hold alone, without a scene (tests)
        end
        local _, p1 = getPlayer1()
        log(string.format("Local co-op %s, player 2 %s", on and "on" or "off",
            valid(state.p2Pawn) and (game.isDead(state.p2Pawn) and "down" or string.format("%.0f cm from player 1",
                valid(p1) and distance(state.p2Pawn:K2_GetActorLocation(), p1:K2_GetActorLocation()) or 0)) or "not in"))
    end

    return localcoop
end
