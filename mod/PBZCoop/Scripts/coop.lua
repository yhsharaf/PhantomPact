-- PBZCoop online co-op: everything that crosses the network. Loaded by main.lua, which passes in its helpers.
--
-- The relay is in main.dll, and api.link calls straight into it (native/lua_link.hpp). What goes across:
--   link.state(...)    the local player, every frame (newest wins, played back smoothly: native/timeline.hpp)
--   link.enemy(line)   host: one enemy, "<number> <x> <y> <z> <yaw> <vx> <vy> <hp> <maxhp> <boss> <posture>" (posture =
--                      "Shachi", which breaks into an execution; - if unknown). Numbers are announced by N events.
--   link.event(line) / link.quick(line)   "<type> <args...>", through sendEvent, which picks the lane:
--     must arrive, in order:
--       D <enemy> <hp> <posture> [L]   client -> host: the client's player took this much health/posture off
--                            it; L = a killing blow (the client's copy is held at 1 health, so the host kills it)
--       K <enemy>            host -> client: this enemy died
--       GK <enemy>           client -> host: it died on the client before the host had it loaded
--       N <number> <enemy> <class>   host -> client: what an enemy number means
--       B <boss>             the sender's game started a boss fight with this enemy
--       R [bell|death]       the sender rested at a bell, or the host died and respawned: enemies respawn on both
--                            PCs (a client's own death respawn isn't sent: only its world refreshes)
--       Y <world>            host -> client: stands for the host's world as loaded: another one, and enemies respawn here
--       C <amount>           the sender gained this much dust (currency): shared rewards
--       I <pickup>           this pickup was taken
--       O <name>             this chest or rubbish pile was opened: the copy here stops paying
--       T <item> <n> <kind>  the game gave the sender this: the same here
--       W <weapon> <0|1>     what the sender holds, and whether it's drawn (moves.lua)
--       S                    from the relay: the partner has just (re)started sync
--     only worth showing now (dropped if late):
--       U, M, A              a montage or ability of the partner or an enemy (moves.lua, puppets.lua)
--       H <hit state tag>    the sender's player started a hit reaction; their ghost plays the same one
--
-- Roles: the host's world is the truth for enemies (positions, health, deaths); the client mirrors it and
-- reports its own hits. Each side shows the other's player as a "ghost" Hun steered by movement input.
-- Who decides what (and why) is written up in docs/AUTHORITY.md.
--
-- With more than two players (PartySize 4 or 6 on the host, beta / experimental) each player has a slot: 1 is the host, 2 to 6
-- the guests.
-- The relay passes a guest's events on (native/party.hpp), and they arrive here as "@<slot> <event>"; the host's come as
-- they always did. Where the code says p, that's one other player: with two players p is net itself, so everything runs
-- as it always has, and in a party each has a table of their own with the same fields (see partners).
--       J <slot>             host -> guests: a player has just joined, and doesn't know what the others hold

return function(api)
    local log, valid, getPlayer1, fmtVec, distance = api.log, api.valid, api.getPlayer1, api.fmtVec, api.distance
    local spawnBesidePlayer1, game = api.spawnBesidePlayer1, api.game

    local GHOST_CLASS = "/Script/Engine.DefaultPawn"
    local SEND_RATE = 125         -- the player goes out every frame, but no more than this many times a second
    local SLOW_S = 0.1            -- health, map and the other things that change rarely are read this often
    local EXTRA_S = 1 / 40        -- modules' ticks (extraTicks); steering runs every frame (frameTicks)
    local GHOST_SNAP_CM = 600     -- walking ghost further than this from its target teleports instead
    local GHOST_PULL = 6.0        -- per second: speed added per cm off the path, so the ghost closes a gap in ~1/6 s
    local GHOST_STILL = 25        -- cm/s; asked to move slower than this, it stands
    local GHOST_JUMP_SPEED = 200  -- cm/s upward as the partner leaves the ground: a jump, and the ghost jumps too
    local GHOST_MAX_SPEED = 2200  -- cm/s: above any sprint or dash
    local GHOST_ACCELERATION = 12000 -- cm/s²: it must take the speed it's given within a frame or two
    local GHOST_SMOOTHING = 0.35  -- sphere ghost: fraction of the remaining distance covered per tick
    local GHOST_CLIMB_CM = 250    -- walking ghost this far above or below its target glides there (it can't climb)
    local GHOST_LAND_CM = 60      -- and walks again once this close in height
    local GHOST_NO_FLOOR_CM = 15  -- falling this far below a partner who's on the ground: there's no floor here for it
    local GHOST_GLIDE_SMOOTHING = 0.3 -- fraction of the remaining distance covered per frame while gliding
    local GHOST_CORRECT_CM = 200  -- further than this from its target it moves even during a replayed move
    local GHOST_BUSY_CM = 30      -- during one, further than this it's pulled gently
    local GHOST_BUSY_PULL = 0.1   -- share of the gap, per frame
    local GHOST_FAILED_LANDING_S = 3.0 -- back in the air this soon after landing: there's no floor here for it
    local GHOST_HOVER_S = 6.0     -- then it stays gliding this long (the partner's ground isn't loaded on this PC)
    local BOSS_JOIN_CM = 5000     -- further than this from the other player's boss, F3 takes you to it: some arenas are
    local BOSS_JOIN_SIDE_CM = 300 -- apart from the map (Xigu's is 20 km up, no way to walk there). This far from its spot
    local JOIN_NEAR_CM = 1500     -- going to the partner from closer than this does nothing (and from 200 m, with the
                                  -- game's own loading screen: see joinPartner)
    local ARRIVE_HOLD_S = 3.0     -- kept in the air this long on arrival, while the ground there loads
    local ARRIVE_WATCH_S = 25.0   -- for this long, a player dropping through ground that isn't there yet is put back
    local ARRIVE_FALL_CM = 300    -- this far below the arrival point counts as dropping through
    local ARRIVE_SETTLE_S = 0.6   -- after the hold, this long to find the ground or start falling
    local BOSS_RETURN_S = 8.0     -- after the boss dies, this long before following a partner who left the arena
    local BOSS_BAR_S = 1.0        -- during the other player's boss fight, how often its bar here is looked at
    local GHOST_AWAY_S = 3.0      -- a sequence or other map must last this long to hide the ghost (climbs, finishers)
    local GAP_LOG_S = 0.5         -- a partner silent this long is logged when they return (choppy-connection reports)
    local BYTES_LOG_S = 60        -- seconds between lines on how much we send
    local ENEMY_RADIUS_CM = 6000  -- host shares enemies within this distance of its player
    local PARTNER_REACH_CM = 12000 -- and around a client this close to it. (Measured: enemies fight a client up to 120 m off, not at 200.)
    local ENEMY_ROUND_S = 0.1     -- each enemy in reach gets a turn this often, a few per frame so none costs a hitch
    local ENEMY_LIST_S = 0.5      -- and who's in reach is worked out this often
    local ENEMY_STALE_S = 1.0     -- a host enemy not updated this long is no longer shared
    local ENEMY_MATCH_CM = 2000   -- client: a same-class enemy this close stands in for a host enemy with another id
    local ASIDE_AFTER_S = 3.0     -- client: an enemy of its own beside the host this long is asked about
    local ASK_AGAIN_S = 10.0      -- and asked about again this often: the host's world changes too
    local PICKUP_S = 1.0          -- between pickup scans
    local MAX_CHEST_NAME = 96     -- what the partner may say a chest is called
    local MAX_ITEM_NAME = 64      -- and an item
    local MAX_GIFT = 999
    local GEAR_S = 5.0            -- between looks at the medicine and accessory lists
    local CURRENCY_S = 0.5        -- between dust checks
    local AGGRO_S = 1.0           -- between ghost aggro refreshes
    local MOVE_NONE = 0           -- EMovementMode::MOVE_None
    local MOVE_WALKING = 1        -- EMovementMode::MOVE_Walking
    local MOVE_FALLING = 3        -- EMovementMode::MOVE_Falling
    local MOVE_FLYING = 5         -- EMovementMode::MOVE_Flying: no gravity while the ghost glides
    local ECC_PAWN = 2            -- ECollisionChannel::ECC_Pawn
    local ECR_IGNORE = 0          -- ECollisionResponse::ECR_Ignore

    local link = api.link          -- nil if main.dll can't be reached: co-op stays off (see start)

    local net = {
        enabled = false,
        role = "host",            -- "host" or "client" (see isHost/isClient)
        ghostMode = "clone",
        target = nil,             -- where to show the partner now: X, Y, Z, Yaw, VX, VY, Hp, MaxHp, Map, Cine, Grounded...
        ghost = nil,
        ghostWalks = false,
        lastRemoteAt = nil,       -- os.clock() of the partner's latest packet
        remoteEnemies = {},       -- client: name -> latest host record
        hostLethal = {},          -- host: enemy id -> true: the host's killing blow on one the guest's game runs
        deadBodies = {},          -- host: actor address -> true: its death was told (see shareEnemy)
        enemyNames = {},          -- client: number -> { name, class }
        enemyNumbers = {},        -- host: name -> number
        announced = {},           -- host: number -> true once the client was told what it means
        deadSent = {},            -- host: enemy name -> true once its death was announced
        guestKilled = {},         -- host: enemy name -> the guest killed its copy while it wasn't loaded here
        guestKillSent = {},       -- client: enemy name -> the host was told of that kill
        pendingDeaths = {},       -- client: host id -> true for a death announced while our copy wasn't loaded
        aside = {},               -- client: address -> { actor, name, since, askedAt, hidden, brain }: enemies of its own beside the host
        notOnHost = {},           -- client: enemy id -> true: the host says it hasn't got this one
        bossAsk = {},             -- client: boss id -> { since, askedAt }: a boss of its own beside the host, asked after
        bringing = {},            -- client: host enemy id -> { since, askedAt }: one this world has no copy of
        broughtBack = {},         -- client: enemy id -> true: dead in this save, brought back for the host (game.bringBack)
        pendingBosses = {},       -- boss id -> true for a fight announced before our copy of the boss was known here
        partnerBosses = {},       -- boss id -> true while the other PC's fight with that boss goes on
        matchSticky = {},         -- client: host id -> address of the local actor matched to it by class/position
        foggedBosses = {},        -- boss id -> where it stood, while we keep its arena's fog walls closed for the other player
        hostKilled = {},          -- client: host id -> true for each death the host announced since the last shared rest
        hostBosses = {},          -- client: host id -> true while the host's fight with that boss goes on
        heldAlive = {},           -- client: actor address -> actor held at Health_Min 1 (only the host kills it)
        healTicks = {},           -- client: host id -> rounds in a row the host's health was clearly above ours
        hostSeen = {},            -- host, PvP: name -> { hp, posture } last tick, to undo the ghost's own hits
        deadSince = nil,          -- os.clock() when the local player died (spectating starts a little later)
        party = nil,              -- with more than two players: how many at most (the host's PartySize); nil with two
        slot = nil,               -- party: this player's number
        peers = {},               -- party: slot -> what's known of that player (a guest's host is net itself)
        peerList = nil,           -- party: the same, in slot order
        lead = nil,               -- party: who net stands for: a guest's host, or the host's first guest who's here
        ghostSlots = {},          -- party: ghost address -> slot
        hitHere = {},             -- client: enemy id -> this player hit it
        guestRuns = {},           -- host: enemy id -> true while the guest's game runs it (see handover)
        guestLines = {},          -- host: enemy id -> the guest's latest record of one its game runs
        mine = {},                -- client: host enemy id -> true while this game runs it (see handover)
        fightOf = {},             -- party: boss id -> the slot of whoever started that fight
        stats = { sent = 0, received = 0, applied = 0, undone = 0 },
    }

    -- Who's who with more than two players, the same on every PC: on the compass, on the map and in tips. (Red is for down.)
    local PLAYERS = {
        { name = "the host (purple)", tint = { R = 0.78, G = 0.55, B = 1.0, A = 1.0 } },
        { name = "player 2 (green)", tint = { R = 0.30, G = 0.85, B = 0.55, A = 1.0 } },
        { name = "player 3 (gold)", tint = { R = 1.0, G = 0.78, B = 0.25, A = 1.0 } },
        { name = "player 4 (blue)", tint = { R = 0.35, G = 0.68, B = 1.0, A = 1.0 } },
        { name = "player 5 (orange)", tint = { R = 1.0, G = 0.50, B = 0.15, A = 1.0 } },
        { name = "player 6 (pink)", tint = { R = 1.0, G = 0.45, B = 0.75, A = 1.0 } },
    }

    local justNet = { net }

    -- Everyone else. With two players that's net, as it always was.
    local function partners()
        return net.peerList or justNet
    end

    -- Who an event came from. No tag: the host, or with two players the partner.
    local function peerOf(from)
        -- (Number 1 is the host: on a guest that's net itself, not one more peer. A fight the host started goes by 1.)
        if from == nil or (from == 1 and net.slot ~= 1) then
            return net
        end
        local p = net.peers[from]
        if p == nil then
            p = { number = from }
            net.peers[from] = p
            if net.peerList then
                net.peerList[#net.peerList + 1] = p
                table.sort(net.peerList, function(a, b) return a.number < b.number end)
            end
        end
        return p
    end

    -- Whether a player's last position is on this map. (One that hasn't said yet counts: it's where they were last.)
    local function sameMap(t)
        return t ~= nil and (t.Map == nil or net.localMap == nil or t.Map == net.localMap)
    end

    -- Everyone's boss bars, as one answer.
    local function countFights()
        local any = false
        for _, p in ipairs(partners()) do
            any = any or p.fights == true
        end
        net.partnerFighting = any
    end

    local function isHost()
        return net.role ~= "client"
    end

    local function isClient()
        return net.role == "client"
    end

    -- tonumber that also turns NaN into nil (a NaN position would teleport actors into nowhere).
    local function num(s)
        local n = tonumber(s)
        -- NaN and infinities (e.g. "1e999") from the network are dropped, never applied.
        if n ~= n or n == math.huge or n == -math.huge then
            return nil
        end
        return n
    end

    -- Amounts the other side may ask for in one event. Far above anything the game produces (a boss drops tens
    -- of thousands of dust, a hit deals thousands), but a malformed or forged event can't hand out billions.
    -- (Idea and caps from appdoze's review of the relay, PR #2.)
    local MAX_EVENT_DUST = 1000000
    local MAX_EVENT_DAMAGE = 1000000

    ------------------------------------------------------------------ events

    -- These are only worth showing now: a move two seconds late is worse than none, and must never hold up a death.
    local QUICK = { U = true, M = true, A = true, H = true, Z = true, SHOT = true }

    local hostWorld = os.time()   -- host: stands for the world as loaded, new with each start and load from the title (see handlers.Y)

    local function sendEvent(kind, ...)
        if not net.enabled then
            return
        end
        local parts = { kind }
        for _, v in ipairs({ ... }) do
            parts[#parts + 1] = tostring(v)
        end
        -- (One line: the partner's inbox is split at line breaks, and with two players one inside a value came out as an event of
        -- its own, made up of the rest. A party's host refused those; here they're flattened.)
        local line = table.concat(parts, " "):gsub("[\r\n]", " ")
        if QUICK[kind] then
            link.quick(line)
        else
            link.event(line)
        end
        net.stats.sent = net.stats.sent + 1
    end

    -- A party's host: a sure event for one guest alone.
    local function sendTo(slot, kind, ...)
        link.send_to(slot, (table.concat({ kind, ... }, " "):gsub("[\r\n]", " ")))
        net.stats.sent = net.stats.sent + 1
    end

    local handlers = {}

    local function processEvents()
        local text = link.events()
        if text == nil then
            return
        end
        for line in text:gmatch("[^\n]+") do
            local kind, rest = line:match("^(%S+)%s*(.*)$")
            local from = kind and kind:match("^@([2-6])$")      -- another guest, or on the host any guest (native/party.hpp)
            if from then
                from = tonumber(from)
                kind, rest = rest:match("^(%S+)%s*(.*)$")
            end
            local h = kind and handlers[kind]
            net.stats.received = net.stats.received + 1
            if h then
                local ok, err = pcall(h, rest, from)
                if not ok then
                    log("event " .. kind .. " error: " .. tostring(err))
                end
            end
        end
    end

    local extraTicksEarly = {}  -- name -> function, run EXTRA_S apart (filled below, joined into extraTicks)
    local frameTicks = {}       -- name -> function(dt), run every frame

    ------------------------------------------------------------------ ghost (the remote player)

    local function spawnGhost(p)
        local ghostClass
        if net.ghostMode == "clone" then
            local _, pawn = getPlayer1()
            ghostClass = valid(pawn) and pawn:GetClass() or nil
        end
        if not valid(ghostClass) then
            ghostClass = StaticFindObject(GHOST_CLASS)
        end
        p.ghost = spawnBesidePlayer1(ghostClass)
        if not valid(p.ghost) then
            return
        end
        if net.party then
            if p.ghostAddr then
                net.ghostSlots[p.ghostAddr] = nil
            end
            net.ghostSlots[p.ghost:GetAddress()] = p.number
        end
        p.ghostAddr, p.ghostAt = p.ghost:GetAddress(), os.clock()
        p.ghostWalks = false
        p.ghostGliding = false
        p.ghostHidden = nil         -- the last one went with the old world: this one is told afresh whether to show
        if net.ghostMode == "clone" then
            -- Steered with movement input (see steerGhost) so the game's own locomotion animations play.
            -- It needs collision for the floor, but should not shove player 1 around.
            p.ghostWalks = pcall(function()
                local cmc = p.ghost.CharacterMovement
                cmc.bRunPhysicsWithNoController = true
                cmc:SetMovementMode(MOVE_WALKING, 0)
            end)
            pcall(function() p.ghost.CapsuleComponent:SetCollisionResponseToChannel(ECC_PAWN, ECR_IGNORE) end)
            pcall(function()
                local cmc = p.ghost.CharacterMovement
                cmc.AirControl = 1.0              -- it follows the partner in the air too
                cmc.MaxAcceleration = GHOST_ACCELERATION
                p.ghostCmc = cmc
            end)
            if game.setupGhost then
                game.setupGhost(p.ghost)
            end
            if game.shieldGhost then
                game.ghostGone()
                game.shieldGhost(p.ghost, not net.pvp)
            end
            if p.look and game.dressGhost then
                game.dressGhost(p.ghost, p.look[1], p.look[2], p.look[3])
            end
            if p.gait and game.setGhostGait then
                -- A new one starts jogging, and its locomotion runs only a moment later: again then.
                local ghost = p.ghost
                game.setGhostGait(ghost, p.gait)
                game.after(1.5, function()
                    if valid(ghost) and ghost == p.ghost and p.gait then
                        game.setGhostGait(ghost, p.gait)
                    end
                end)
            end
        end
        if not p.ghostWalks then
            -- Teleported every tick, so its own movement (gravity, root motion) must stay out of the way.
            p.ghost:SetActorEnableCollision(false)
            pcall(function() p.ghost.CharacterMovement:DisableMovement() end)
        end
        local t = p.target
        p.ghost:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
        log("Remote player ghost spawned.")
    end

    -- The ghost disappears while the remote player is dead (health 0) or on another map, and comes back when
    -- they revive or arrive (the snap distance then moves it straight to them).
    local function updateGhostVisibility(p)
        if not valid(p.ghost) or p.target == nil then
            return
        end
        local t = p.target
        local otherMap = t.Map ~= nil and net.localMap ~= nil and t.Map ~= net.localMap
        -- Only "down" after a full second at 0 HP: a single 0 read during a teleport or loading hitch made the
        -- ghost flicker in the first live two-copy test.
        local zero = t.MaxHp ~= nil and t.MaxHp > 0 and t.Hp ~= nil and t.Hp <= 0
        if zero then
            p.zeroSince = p.zeroSince or os.clock()
        else
            p.zeroSince = nil
        end
        local dead = zero and (os.clock() - p.zeroSince) >= 1.0
        local gone = p.partnerGone == true       -- see watchPartner
        -- In a cutscene the partner isn't really playing: their ghost would stand idle in your world. And in one of yours it
        -- stood in the shot, which a player asked to be rid of. Short sequences are part of play, and a ghost hidden for each
        -- one blinked in and out.
        local away = otherMap or t.Cine == true or (game.inCutscene and game.inCutscene())
        if away then
            p.awaySince = p.awaySince or os.clock()
        else
            p.awaySince = nil
        end
        local hide = dead or gone or (away and os.clock() - p.awaySince >= GHOST_AWAY_S)
        if hide ~= p.ghostHidden then
            p.ghostHidden = hide
            p.ghostGliding = false
            pcall(function()
                p.ghost:SetActorHiddenInGame(hide)
                p.ghost:SetActorEnableCollision(p.ghostWalks and not hide)
                if p.ghostWalks then
                    -- Without collision it would fall through the world: 20 km by the time it came back.
                    p.ghost.CharacterMovement:SetMovementMode(hide and MOVE_NONE or MOVE_WALKING, 0)
                end
            end)
            if api.moves then
                pcall(api.moves.hideGear, p.ghost, hide)      -- its weapon is an actor of its own
            end
            if isHost() then
                game.ghostInFight(p.ghost, not hide, (game.enemiesSoFar()))
            end
            if hide then
                log("Ghost hidden: the other player is " .. (gone and "gone" or dead and "down"
                    or t.Cine and "in a cutscene" or ("on map " .. tostring(t.Map))) .. ".")
            else
                log("Ghost visible again.")
            end
        end
    end

    local function updateVisibility()
        for _, p in ipairs(partners()) do
            updateGhostVisibility(p)
        end
    end

    -- The ghost only walks, so a partner climbing a cliff left it pressing against the rock until the height gap
    -- reached the snap distance. A big gap in height moves it directly instead, and so does a climb from its first frame
    -- (the game flies the player along the climb's montage, which plays on the ghost too). True while gliding.
    local function glideGhost(p, cur, t)
        local gap = math.abs(t.Z - cur.Z)
        if not p.ghostGliding then
            -- The partner stands on ground this PC hasn't loaded (it isn't, this far from us): left to fall, the ghost sank
            -- metres into the distant scenery, out of sight, and came back, again every few seconds.
            local noFloor = t.Grounded and t.Z - cur.Z > GHOST_NO_FLOOR_CM and p.ghostCmc.MovementMode == MOVE_FALLING
            if gap < GHOST_CLIMB_CM and not t.Climbing and not noFloor then
                return false
            end
            p.ghostGliding = true
            p.ghost.CharacterMovement:SetMovementMode(MOVE_FLYING, 0)
            if t.Climbing then
                p.ghostHoverUntil = nil
            elseif p.ghostLandedAt and os.clock() - p.ghostLandedAt < GHOST_FAILED_LANDING_S then
                p.ghostHoverUntil = os.clock() + GHOST_HOVER_S
            else
                log("Ghost gliding: the other player is " .. math.floor(gap) .. " cm higher or lower.")
            end
        elseif gap <= GHOST_LAND_CM and t.Grounded and os.clock() >= (p.ghostHoverUntil or 0) then
            -- (Not while they hang on a cliff: a ghost walking in mid-air falls, then glides back up, again and again.)
            p.ghostGliding = false
            p.ghostLandedAt = os.clock()
            p.ghost.CharacterMovement:SetMovementMode(MOVE_WALKING, 0)
            return false
        end
        -- (The played path is already smooth, and a climb must stay on it: its hands are on the rungs.)
        local a = (t.Climbing or distance(cur, t) > GHOST_SNAP_CM) and 1.0 or GHOST_GLIDE_SMOOTHING
        p.ghost:K2_SetActorLocationAndRotation(
            { X = cur.X + (t.X - cur.X) * a, Y = cur.Y + (t.Y - cur.Y) * a, Z = cur.Z + (t.Z - cur.Z) * a },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
        return true
    end

    -- The ghost's speed is the partner's own along the path being played, plus a pull back onto it if it has drifted, so
    -- it stays on the path at any speed instead of trailing behind. Its own movement keeps it on the ground and plays the
    -- game's locomotion animations.
    local function steerGhost(p)
        if not valid(p.ghost) or p.target == nil or (p.ghostWalks and not valid(p.ghostCmc)) then
            return
        end
        local cur
        if net.party then
            -- Three of these a frame: nothing for a ghost nobody sees, and its place straight from memory (game.where).
            if p.ghostHidden then
                return
            end
            local x, y, z = game.where(p.ghost, p.ghostAddr)
            if x == nil then
                return
            end
            cur = p.spot or {}
            cur.X, cur.Y, cur.Z = x, y, z
            p.spot = cur
        else
            cur = p.ghost:K2_GetActorLocation()
        end
        local t = p.target
        if p.ghostHidden or (p.ghostWalks and glideGhost(p, cur, t)) then
            return
        end
        -- The game's own launch, not a jump button: nobody controls the ghost, so Jump() would do nothing. Asked of the
        -- ghost itself: a jump during a replayed move counts too, and it can't launch twice.
        if p.ghostWalks and t.Falling and t.VZ > GHOST_JUMP_SPEED and p.ghostCmc.MovementMode == MOVE_WALKING then
            p.ghost:LaunchCharacter({ X = t.VX, Y = t.VY, Z = t.VZ }, true, true)
        end
        local dx, dy = t.X - cur.X, t.Y - cur.Y
        local dist = math.sqrt(dx * dx + dy * dy)
        if game.ghostBusy and game.ghostBusy(p.ghost) and dist < GHOST_CORRECT_CM then
            -- Mid attack/dodge the move's own motion plays out, with a soft pull so a knockback or a turn doesn't leave
            -- it metres off by the time the move ends.
            if dist > GHOST_BUSY_CM then
                p.ghost:K2_SetActorLocation({ X = cur.X + dx * GHOST_BUSY_PULL, Y = cur.Y + dy * GHOST_BUSY_PULL, Z = cur.Z },
                    false, {}, true)
            end
            p.ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false)
            return
        end
        if p.ghostWalks then
            if dist > GHOST_SNAP_CM or math.abs(t.Z - cur.Z) > GHOST_SNAP_CM then
                -- Too far behind (teleport, fall, cutscene): jump straight there.
                p.ghost:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
                    { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
                return
            end
            local vx, vy = t.VX + dx * GHOST_PULL, t.VY + dy * GHOST_PULL
            local speed = math.sqrt(vx * vx + vy * vy)
            if speed > GHOST_STILL then
                -- PBZ leaves MaxWalkSpeed at 0 on an unpossessed Hun (its locomotion system sets it for players).
                p.ghostCmc.MaxWalkSpeed = math.min(GHOST_MAX_SPEED, speed)
                p.ghost:AddMovementInput({ X = vx / speed, Y = vy / speed, Z = 0.0 }, 1.0, false)
            end
            p.ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false)
            return
        end
        local a = GHOST_SMOOTHING
        p.ghost:K2_SetActorLocationAndRotation(
            { X = cur.X + (t.X - cur.X) * a, Y = cur.Y + (t.Y - cur.Y) * a, Z = cur.Z + (t.Z - cur.Z) * a },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
    end

    local function steerGhosts()
        for _, p in ipairs(partners()) do
            steerGhost(p)
        end
    end

    handlers.M = function(rest, from)
        local path, yaw = rest:match("^(%S+)%s*(%S*)")
        -- (On the sender's own ghost: in a party, net.ghost is the lead's, and every player's move played on it.)
        local ghost = net.party and peerOf(from).ghost or net.ghost
        if path and valid(ghost) and game.playMove then
            game.playMove(ghost, path, tonumber(yaw))
        end
    end

    ------------------------------------------------------------------ enemies

    -- Enemies within ENEMY_RADIUS_CM of the local player, or (second origin) of the other player: the host shares
    -- the enemies around a client near it too, so that client still fights the host's enemy (otherwise it would be the
    -- client's own, and could die there while alive for the host). Further off they sleep on the host, since the game wakes
    -- enemies around its own player only, and a copy waiting for the host's orders would stand and watch: those stay the
    -- client's own, with their own AI, and a kill reaches the host as GK.
    -- Worked out a few each frame: reading every loaded enemy at once stood out as a hitch twice a second.
    local reach = { list = {}, addrs = {}, at = 1, near = {} }     -- near: address -> { actor, loc, addr }
    -- The work on enemies is spread the same way: every enemy in reach gets a turn each ENEMY_ROUND_S.
    local round = { queue = {}, at = 1, startedAt = -1e9, number = 0 }

    local function gap3d(a, b)
        return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
    end

    local function inReach(x, y, z, o)
        local dx, dy, dz = x - o.X, y - o.Y, z - o.Z
        return dx * dx + dy * dy + dz * dz <= ENEMY_RADIUS_CM * ENEMY_RADIUS_CM
    end

    -- A party's host: where the guests near enough are. Kept, not made anew: this runs every frame.
    local guestSpots = {}
    local function guestsNear(origin)
        local n = 0
        for _, p in ipairs(partners()) do
            local t = p.target
            if t ~= nil and not p.ghostHidden and gap3d(origin, t) <= PARTNER_REACH_CM then
                n = n + 1
                guestSpots[n] = t
            end
        end
        for i = #guestSpots, n + 1, -1 do
            guestSpots[i] = nil
        end
        return guestSpots
    end

    local function nearAny(x, y, z, spots)
        for _, o in ipairs(spots) do
            if inReach(x, y, z, o) then
                return true
            end
        end
        return false
    end

    local function updateReach(origin, origin2, dt, spots)
        if reach.at > #reach.list then
            reach.list, reach.addrs = game.listEnemies()
            reach.at = 1
        end
        for _ = 1, math.ceil(#reach.list * math.max(dt, 0.004) / ENEMY_LIST_S) do
            local e, addr = reach.list[reach.at], reach.addrs[reach.at]
            if e == nil then
                return
            end
            reach.at = reach.at + 1
            local x, y, z = nil, nil, nil
            if addr ~= net.ghostAddr and not net.ghostSlots[addr] then    -- (an address a ghost took over from an enemy, until facts are cleared)
                x, y, z = game.where(e, addr)
            end
            if x ~= nil and (inReach(x, y, z, origin) or (origin2 ~= nil and inReach(x, y, z, origin2))
                or (spots ~= nil and nearAny(x, y, z, spots))) then
                local near = reach.near[addr]
                if near then
                    near.actor, near.loc.X, near.loc.Y, near.loc.Z = e, x, y, z
                else
                    reach.near[addr] = { actor = e, loc = { X = x, Y = y, Z = z }, addr = addr }
                end
            else
                reach.near[addr] = nil
            end
        end
    end

    local enemyByName = {}    -- name -> actor, kept current round by round on both sides

    -- An id both PCs agree on (see game.enemyId): the spawner's designer id when a spawner made the enemy.
    local function enemyName(actor, addr)
        if game.enemyId then
            return game.enemyId(actor, addr)
        end
        return actor:GetFName():ToString()
    end

    local function enemyClass(actor)
        return actor:GetClass():GetFName():ToString()
    end

    -- A health/posture drop right after the ghost replayed a move, while the local player started none, is the
    -- ghost's hit. The ghost is the other player, whose hits arrive as reported damage ("D"); its own native hit
    -- (it only has an Attack stat in PvP) would count the same swing twice.
    local ATTRIBUTION_S = 1.5
    local function ghostsHit()
        return game.ghostMoveRecent and game.ghostMoveRecent(ATTRIBUTION_S)
            and not game.localMoveRecent(ATTRIBUTION_S)
    end

    -- A copy's health moves for other reasons too: its own moves, which replay for real, and being scaled or unloaded. Sent
    -- as hits, those took thousands off the host's enemies, even killed them. So it's this player's hit only if they've
    -- moved lately and stand near enough to have landed one.
    local OWN_HIT_S = 3.0
    local OWN_HIT_CM = 6000

    local function ownHit(actor)
        local _, pawn = getPlayer1()
        return game.localMoveRecent(OWN_HIT_S) and valid(pawn)
            and distance(actor:K2_GetActorLocation(), pawn:K2_GetActorLocation()) <= OWN_HIT_CM
    end

    local function undoHit(actor, prevHp, prevPosture)
        if prevHp and game.setHealth then
            game.setHealth(actor, prevHp)
        end
        if prevPosture and game.setPosture then
            game.setPosture(actor, prevPosture)
        end
        net.stats.undone = net.stats.undone + 1
    end

    -- The number that stands for this enemy in link.enemy lines: names are long and go out once, as a sure event.
    local function enemyNumber(actor, name)
        local n = net.enemyNumbers[name]
        if n == nil then
            net.lastEnemyNumber = (net.lastEnemyNumber or 0) + 1
            n = net.lastEnemyNumber
            net.enemyNumbers[name] = n
        end
        if not net.announced[n] then
            net.announced[n] = true
            sendEvent("N", n, name, enemyClass(actor))
        end
        return n
    end

    -- The other player's boss fight, mirrored on our copy of that boss: boss bar and closed fog walls.
    local function mirrorBossFight(name, actor)
        if game.showBossBar then
            game.showBossBar(actor)
        end
        if game.setBossFog then
            local at = actor:K2_GetActorLocation()
            net.foggedBosses[name] = { X = at.X, Y = at.Y, Z = at.Z }
            game.setBossFog(at, true)
        end
    end

    -- That boss is dead: its bar goes and the walls open, on both PCs. The game's own script only opens the walls of a
    -- fight it started itself, so they're opened whoever closed them. (actor: our copy, nil if it isn't loaded.)
    local function endBossFight(name, actor)
        local at = net.foggedBosses[name]
        net.foggedBosses[name] = nil
        net.partnerBosses[name] = nil
        net.pendingBosses[name] = nil
        if net.joinedBoss == name then
            net.joinedBoss = nil
            if net.joinedFar then
                net.bossOverAt = os.clock() + BOSS_RETURN_S     -- (an arena apart from the map has no way back)
            end
        end
        if valid(actor) then
            at = at or actor:K2_GetActorLocation()
            if game.hideBossBar then
                game.hideBossBar(actor)
            end
        end
        if at and game.setBossFog then
            game.setBossFog(at, false)
        end
    end

    -- Those fights end here, with no word from the boss: their owner left, or stopped. whose: that player's number (nil for all).
    local function endFights(whose)
        for name in pairs(net.partnerBosses) do
            if whose == nil or net.fightOf[name] == whose then
                endBossFight(name, enemyByName[name])
                net.fightOf[name] = nil
            end
        end
    end

    -- Sync off, the partner gone, a respawn: open every fog wall we closed for the other player's boss fights.
    local function reopenFog()
        for _, at in pairs(net.foggedBosses) do
            if game.setBossFog then
                pcall(game.setBossFog, at, false)
            end
        end
        net.foggedBosses = {}
    end

    -- Host: a kill's items for the client, one pickup event each. paid collects what to say in the log.
    local function sendItems(name, items, paid)
        for _, item in ipairs(items) do
            for _ = 1, item.count do
                sendEvent("I", "loot:" .. name, item.id, item.kind or "-")
            end
            paid[#paid + 1] = item.id .. " x" .. item.count
        end
    end

    -- Host: the client's hit killed this enemy. The game's own loot roll didn't run (see game.rollLoot), so it's
    -- rolled here, once. Dust goes to the host like any kill's and reaches the client as shared dust ("C"); items go to
    -- both, unless the client's game already paid its player (theirsPaid: the death ran there first).
    local function payKillLoot(name, actor, theirsPaid)
        local dust, items, level = game.rollLoot(actor)
        local _, pawn = getPlayer1()
        local paid = {}
        if dust > 0 and valid(pawn) and pcall(function() pawn:ChangeDustNumInternal(dust) end) then
            paid[#paid + 1] = dust .. " dust"
        end
        for _, item in ipairs(items) do
            for _ = 1, item.count do
                game.grantLoot(pawn, item.id, item.kind)
            end
            if theirsPaid then
                paid[#paid + 1] = item.id .. " x" .. item.count
            end
        end
        if not theirsPaid then
            sendItems(name, items, paid)
        end
        if #paid > 0 then
            log(string.format("Your partner's kill (%s, level %d): %s.", name, level, table.concat(paid, ", ")))
        end
    end

    -- A party's host, an enemy's aggro turn: every ghost here goes on its hatred list, and its focus is steered among all the
    -- players near it. Their ghosts' places are what the relay last said: no calls into the game for each of them.
    local function aggroParty(actor, addr, x, y, z, hp)
        local here = {}
        for _, p in ipairs(partners()) do
            if valid(p.ghost) and not p.ghostHidden and not p.silent and p.target then
                game.hateGhost(actor, p.ghost, addr, x, y, z, p.number, p.target)
                here[#here + 1] = { body = p.ghost, addr = p.ghostAddr, at = p.target, slot = p.number }
            end
        end
        local _, pawn = getPlayer1()
        if valid(pawn) and not game.isDead(pawn) and net.localLoc then
            here[#here + 1] = { body = pawn, addr = pawn:GetAddress(), at = net.localLoc, slot = net.slot, mine = true }
        end
        if #here >= 2 then
            game.steerPartyFocus(actor, addr, x, y, z, hp, here)
        end
    end

    -- The host's game wakes enemies for its own player alone: its optimizer and its fight areas, which only ever take the host
    -- in, kept the ones by a guest some way off asleep, and their copies on the guest's side stood there with them, never
    -- swinging. So with two players apart, an enemy clearly nearer the guest is run by the guest's game, where the guest is the
    -- player and it wakes as the game always does, and the host's copy follows the guest's lines and moves as a guest's copies
    -- follow the host's. It's the host's again once the two are together, once it's clearly nearer the host, or when the
    -- guest's game goes quiet about it. Bosses, one fighting the host, and anything without a spawner's id (which the two PCs
    -- might name apart) stay the host's. Two players only: a party's relay carries enemy lines from the host alone.
    local handover = {
        APART_CM = 2500,        -- the two players further apart than this are apart
        TOGETHER_CM = 1500,     -- and back within this, together
        NEARER_CM = 1000,       -- an enemy changes hands once it's this much nearer the other player
        FIGHT_CM = 3000,        -- one after the host and this close to it is in the host's fight
        QUIET_S = 2.0,          -- this long with no line from the guest's game, it's the host's again
        RETRY_S = 10.0,         -- and isn't handed over again this soon
        on = false,             -- host, this round: the two are apart, and the guest's game may run enemies
        seen = {},              -- host: id -> { hp, posture, addr } of a copy the guest's game runs, as left last turn
        since = {},             -- host: id -> net.frameNow when it was handed over
        retryAt = {},           -- host: id -> os.clock() before which it isn't handed over again
    }

    -- Host, one enemy's turn: announce its death (reliably), or send where it is.
    local function shareEnemy(actor, addr, aggro)
        local name = enemyName(actor, addr)
        -- (Not a body over the live enemy of the same id: a guest's hit on that id landed on the body and was lost.)
        local had = enemyByName[name]
        if had == actor or not (valid(had) and not game.isDead(had) and game.isDead(actor)) then
            enemyByName[name] = actor
        end
        local x, y, z, yaw, vx, vy, _, _, hp, maxhp, posture = game.read(actor, addr)
        if net.pvp and hp and hp > 0 then
            -- Only in PvP does the ghost carry a real Attack stat, so only then can it hurt enemies here.
            local prev = net.hostSeen[name]
            if prev and prev.addr == addr and ghostsHit()
                and ((prev.hp and hp < prev.hp - 0.5) or (prev.posture and posture and posture < prev.posture - 0.5)) then
                undoHit(actor, prev.hp, prev.posture)
                hp, posture = prev.hp, prev.posture
            end
            net.hostSeen[name] = { hp = hp, posture = posture, addr = addr }
        end
        -- At 0 health it's dead, and that's all most turns need; asking the game costs more and rarely says otherwise.
        local dead = hp ~= nil and hp <= 0
        -- (One already announced is asked every turn: dead by the game's word at full health, it mustn't flip back.)
        if not dead and game.isDead and (round.number % 3 == 0 or net.deadSent[name]) then
            dead = game.isDead(actor)
        end
        local paidThere = false
        if not dead and net.guestKilled[name] and game.kill then
            net.guestKilled[name] = nil
            if net.guestRuns[name] then
                handover.drop(actor, addr, name)
            end
            if net.hostLethal[name] then
                -- The host's own killing blow on one the guest's game ran: the death ran there and paid the guest its
                -- items, and the host only the dust, by C. The host's items are rolled here, as its own kill's would be.
                net.hostLethal[name] = nil
                local _, items = game.rollLoot(actor)
                local _, pawn = getPlayer1()
                for _, item in ipairs(items or {}) do
                    for _ = 1, item.count do
                        game.grantLoot(pawn, item.id, item.kind)
                    end
                end
            end
            -- (Not left standing frozen till it goes: it dies as a death looks here, as a guest's copies do.)
            if game.dissolveKill and not (game.isBoss and game.isBoss(actor, addr)) then
                game.dissolveKill(actor)
            else
                game.kill(actor)
            end
            dead = true
            paidThere = true        -- the guest's game ran that death itself, loot and all
        end
        if dead then
            if net.guestRuns[name] then
                handover.drop(actor, addr, name)
            end
            -- (And by the body: a rest forgets the names, and a spawner's new enemy under the same id clears its name each
            -- turn, so the old body's turn told its death again, every round: boss items paid twice, and the guest's live
            -- copy killed.)
            if not net.deadSent[name] and not net.deadBodies[addr] then
                net.deadSent[name] = true
                net.deadBodies[addr] = true
                sendEvent("K", name)
                log("Enemy died here: " .. name .. "; telling the other player.")
                if game.markBeaten then
                    game.markBeaten(name)
                end
                local boss = net.partnerBosses[name] or net.pendingBosses[name] or (game.isBoss and game.isBoss(actor))
                if boss and not paidThere and game.rollLoot then
                    -- The game paid the host. A boss's items are the client's too.
                    local _, items = game.rollLoot(actor)
                    local paid = {}
                    sendItems(name, items, paid)
                    if #paid > 0 then
                        log("Boss items for your partner too: " .. table.concat(paid, ", ") .. ".")
                    end
                end
                if boss then
                    endBossFight(name, actor)
                end
            end
        elseif hp ~= nil and maxhp ~= nil then
            if net.pendingBosses[name] then
                -- The guest's boss fight, on a boss that had to spawn here first.
                net.pendingBosses[name] = nil
                log("Boss " .. name .. " is here now: showing the other player's fight.")
                mirrorBossFight(name, actor)
            end
            -- (No health read = stale actor: left out rather than sent as 0/0, which the client would apply.)
            -- Alive (again, after a bell respawn): its next death must be announced too.
            net.deadSent[name] = nil
            net.deadBodies[addr] = nil
            if handover.guestRuns(name, actor, addr, x, y, z) and handover.follow(name, actor, addr, hp, posture) then
                return              -- (the guest's game runs it: what it does comes from there)
            end
            if api.puppets then
                api.puppets.watchHost(name, actor, addr)
            end
            if yaw == yaw and x == x and y == y and z == z then
                local boss = game.isBoss and game.isBoss(actor, addr) and 1 or 0
                -- "-" = unknown posture; the client leaves its own alone instead of zeroing it.
                link.enemy(string.format("%d %.0f %.0f %.0f %.0f %.0f %.0f %.1f %.1f %d %s", enemyNumber(actor, name),
                    x, y, z, yaw, vx == vx and vx or 0, vy == vy and vy or 0, hp, maxhp, boss,
                    posture ~= nil and string.format("%.1f", posture) or "-"))
            end
            if net.party then
                if aggro then
                    aggroParty(actor, addr, x, y, z, hp)
                end
            elseif aggro and valid(net.ghost) and game.hateGhost and not net.ghostHidden and not net.silent then
                game.hateGhost(actor, net.ghost, addr, x, y, z)
                if not net.pvp then
                    local _, pawn = getPlayer1()
                    if valid(pawn) and not game.isDead(pawn) then
                        game.steerFocus(actor, addr, x, y, z, hp, pawn, net.ghost)
                    end
                end
            end
        end
    end

    -- id is the HOST's id for this enemy (it may differ from our own when matched by class and position).
    -- lethal: our copy is held at 1 health (only the host kills it), so a killing blow can't show its full damage
    -- here; it's sent as lethal and the host kills the enemy.
    -- A host reports its hits on one the guest's game runs (handover), the other way round.
    -- With the reaction the hit made here (puppets.reactionOf: montage, position, hit state), for the enemy itself to show.
    local function reportHit(id, enemy, hpDamage, postureDamage, lethal)
        if net.enabled and (isClient() or net.guestRuns[id]) and valid(enemy) then
            local path, pos, tag
            if api.puppets and not lethal then
                path, pos, tag = api.puppets.reactionOf(enemy)
            end
            sendEvent("D", id, string.format("%.1f", hpDamage), string.format("%.1f", postureDamage or 0),
                lethal and "L" or "-", path or "-", string.format("%.2f", pos or 0), tag or "-")
            net.stats.hitsReported = (net.stats.hitsReported or 0) + 1
            if isClient() and hpDamage > 0 then
                net.hitHere[id] = true      -- (see GK in syncEnemy)
            end
        end
    end

    -- Client: which local enemy is each of the host's? Same id first; then the actor this id was matched to
    -- before (sticky, while it's loaded and alive); otherwise the nearest still-unmatched local enemy of the same
    -- class within ENEMY_MATCH_CM (covers enemies whose ids differ between PCs). Ids go in sorted order, so two
    -- same-class enemies pair up the same way every tick (pairs() order is arbitrary).
    local function matchRemoteEnemies(locals)
        local byId, byAddr, used, matched = {}, {}, {}, {}
        -- (Two can share an id: a spawner's new enemy while the old body still lies there. The live one is that id's, or
        -- the body was synced and the live one, unheld, fought this player on its own.)
        local isDead = game.isDead or function() return false end
        for _, e in pairs(locals) do
            local id = enemyName(e.actor, e.addr)
            local had = byId[id]
            if not had or (isDead(had.actor) and not isDead(e.actor)) then
                byId[id] = e
            end
            byAddr[e.addr] = e
        end
        local ids = {}
        for id in pairs(net.remoteEnemies) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        local function take(id, e)
            matched[id] = e.actor
            used[e.addr] = true
        end
        for _, id in ipairs(ids) do
            local e = byId[id]
            -- (Not a body: matched to a host enemy that's alive, its death here was sent on as the guest's kill, GK, and
            -- killed the host's, a fresh one after a rest too.)
            if e and not used[e.addr] and not isDead(e.actor) then
                take(id, e)
            end
        end
        for _, id in ipairs(ids) do
            local e = byAddr[net.matchSticky[id]]
            if matched[id] == nil and e and not used[e.addr] and not (game.isDead and game.isDead(e.actor)) then
                -- (Still the same kind: another enemy can be at a gone one's address, and was steered as the host's.)
                local want = net.remoteEnemies[id] and net.remoteEnemies[id].Class
                e.class = e.class or (want and enemyClass(e.actor))
                if not want or e.class == want then
                    take(id, e)
                end
            end
        end
        for _, id in ipairs(ids) do
            local r = net.remoteEnemies[id]
            -- (Never a ghost twin's id: this PC makes its own copy of it (twins.lua), and until then the nearest of the
            -- class was one of this world's own enemies, steered as the twin and killed with it.)
            if matched[id] == nil and r.Class and not id:match("^tw%d+:") then
                local best, bestD = nil, ENEMY_MATCH_CM
                for _, e in pairs(locals) do
                    -- (Not a body either: one lying where the host's live enemy stood was paired as it, and as one
                    -- found it was never brought back, so the host's enemy had no body here to hit.)
                    if not used[e.addr] and not isDead(e.actor) then
                        e.class = e.class or enemyClass(e.actor)    -- three calls through UE4SS, for each pair, each round
                        if e.class == r.Class then
                            local d = distance(e.loc, r)
                            if d < bestD then
                                best, bestD = e, d
                            end
                        end
                    end
                end
                if best then
                    take(id, best)
                end
            end
        end
        -- Remember the pairings. One whose id skipped this snapshot stays while its actor is still loaded.
        local sticky = {}
        for id, addr in pairs(net.matchSticky) do
            if byAddr[addr] and net.remoteEnemies[id] == nil then
                sticky[id] = addr
            end
        end
        for _, id in ipairs(ids) do
            if matched[id] then
                sticky[id] = matched[id]:GetAddress()
            end
        end
        net.matchSticky = sticky
        -- Local enemies the host didn't mention keep their own id (their hits are still reported).
        local paired, own = {}, {}
        for _, addr in pairs(sticky) do
            paired[addr] = true
        end
        for _, e in pairs(locals) do
            if not used[e.addr] then
                local id = enemyName(e.actor, e.addr)
                -- (Never over the one paired with the host's under that id. Nor a body under the id of one alive there,
                -- unless it's this player's kill still to tell (GK, in syncEnemy): any other was steered as the host's live
                -- enemy and, being found, never brought back.)
                local body = net.remoteEnemies[id] and isDead(e.actor)
                    and not ((net.hitHere[id] or net.mine[id]) and not net.guestKillSent[id])
                if matched[id] == nil and not body then
                    matched[id] = e.actor
                end
                if not paired[e.addr] then
                    own[#own + 1] = e
                end
            end
        end
        return matched, own
    end

    local function showAside(keep)
        for addr, a in pairs(net.aside) do
            if not (keep and keep[addr]) and a.hidden and valid(a.actor) then
                game.stepAside(a.actor, false)
                game.startAI(a.actor)
            end
        end
        net.aside = keep or {}
    end

    -- Each player keeps their own save, so the two worlds can disagree on who's dead, and near the host its world leads. An
    -- enemy this world has and the host's hasn't would fight this player with nothing for the host to see or hit. Not being
    -- in the host's lines proves nothing: those only cover what's near it, and a copy here may have run after this player. So
    -- the host is asked, and only "I haven't got it" counts. Then it steps out of the way: hidden, not killed, so nothing
    -- of it reaches this save, and back once the host has moved on or turns out to have it. Bosses stay: a hidden one would
    -- start its fight all the same. But a boss is asked after too, and one the host's world has beaten is beaten here before
    -- any fight (BEATEN): this player never meets a boss the host is past. Only spawner ids: any other name is this PC's alone.
    local function setAside(own, now)
        local t = net.target
        if t and not net.partnerGone and os.clock() - (net.lastRemoteAt or -1e9) > ENEMY_STALE_S then
            -- (A hitch on the host's side says nothing about its enemies: nothing changes. But the hidden ones are kept
            -- stopped: the game starts their AI again by itself, and over a load's silence one walked about unseen and hit.)
            for _, a in pairs(net.aside) do
                if a.hidden and valid(a.actor) then
                    a.brain = game.stopAI(a.actor, a.brain)
                end
            end
            return
        end
        local here = t ~= nil and not net.partnerGone and t.Map == net.localMap
        local kept, gone, bosses = {}, 0, {}
        for _, e in ipairs(own) do
            local name = enemyName(e.actor, e.addr)
            local near = here and name:sub(1, 3) == "sp:" and inReach(e.loc.X, e.loc.Y, e.loc.Z, t) and not game.isDead(e.actor)
            if near and game.isBoss(e.actor, e.addr) then
                local a = net.bossAsk[name] or { since = now, askedAt = -1e9 }
                bosses[name] = a
                if now - a.since >= ASIDE_AFTER_S and now - a.askedAt >= ASK_AGAIN_S then
                    a.askedAt = now
                    sendEvent("HAS", name)
                end
            elseif near then
                -- (A new enemy at a gone one's address isn't that one: it took its record, stopped and never woke.)
                local a = net.aside[e.addr]
                if not a or a.name ~= name then
                    a = { actor = e.actor, name = name, since = now, askedAt = -1e9 }
                end
                kept[e.addr] = a
                if a.hidden then
                    a.brain = game.stopAI(e.actor, a.brain)     -- (the game starts a stopped AI again by itself)
                elseif net.notOnHost[name] then
                    a.hidden = true
                    game.stepAside(e.actor, true)
                    a.brain = game.stopAI(e.actor)
                    gone = gone + 1
                elseif now - a.since >= ASIDE_AFTER_S and now - a.askedAt >= ASK_AGAIN_S then
                    a.askedAt = now
                    sendEvent("HAS", name)
                end
            end
        end
        showAside(kept)
        net.bossAsk = bosses
        if gone > 0 then
            log(gone .. " enemies here aren't in the host's world: out of the way while you're near the host.")
        end
    end

    -- Client: pull its copies of the host's enemies into place and match their health and posture.
    -- The client's own hits are found by watching health/posture drop between ticks (PBZ calls OnDamage
    -- natively, so a UE4SS hook never sees it) and reported to the host. Syncing only ever LOWERS health and
    -- posture: the host's numbers are a round trip old and don't include the client's newest hits yet.
    local seen = {}           -- client: name -> { hp, posture, addr } as left by the previous tick

    -- The host's health this many snapshots in a row clearly above ours is a heal (a boss phase that restores
    -- health): taken over. Our copy dips below the host's for a round trip after each of our own hits, which
    -- this must not mistake for a heal, so it waits a full second.
    local HEAL_TICKS = 20
    local HELD_HP = 1             -- the floor the client's copies of host enemies are held at

    -- keep: address -> actor still held this tick (nil releases every held copy).
    local function releaseHeld(keep)
        for addr, actor in pairs(net.heldAlive) do
            if not (keep and keep[addr]) and valid(actor) and game.setMinHealth then
                game.setMinHealth(actor, 0)
            end
        end
        net.heldAlive = keep or {}
        if api.puppets then
            if keep then
                api.puppets.releaseExcept(keep)
            else
                api.puppets.releaseAll()
            end
        end
    end

    -- Client, one enemy's turn. nextSeen and held collect the round's results.
    local function syncEnemy(name, actor, nextSeen, held)
        local addr = actor:GetAddress()
        if net.pendingDeaths[name] then
            -- The host announced this death while our copy wasn't loaded: kill it now that it is. (Unless the host has it
            -- alive: a refresh brought it back there.)
            net.pendingDeaths[name] = nil
            if game.kill and not net.remoteEnemies[name] and not (game.isDead and game.isDead(actor)) then
                game.kill(actor)
                log("Host said " .. name .. " died earlier; killed it here now that it's loaded.")
            end
            if game.markBeaten then
                game.markBeaten(name)
            end
        elseif not (game.isDead and game.isDead(actor)) then
            if net.pendingBosses[name] then
                -- The host's boss fight started before our copy of the boss was matched: mirror it now.
                net.pendingBosses[name] = nil
                log("Host's boss fight with " .. name .. " now matched here.")
                mirrorBossFight(name, actor)
            end
            local hp, maxhp = nil, nil
            if game.getHealth then
                hp, maxhp = game.getHealth(actor)
            end
            local posture = game.getPosture and game.getPosture(actor)
            local prev = seen[name]
            if prev and prev.addr ~= addr then
                prev = nil    -- this id now stands for another actor: its health isn't comparable
            end
            if prev and hp and prev.hp then
                local dHp = prev.hp - hp
                local dPosture = (prev.posture and posture) and (prev.posture - posture) or 0
                if dHp > 0.5 or dPosture > 0.5 then
                    if ghostsHit() and (net.pvp or dHp <= 0.5) then
                        -- The host's swing, replayed here: the host's own world already took it.
                        undoHit(actor, prev.hp, prev.posture)
                        hp, posture = prev.hp, prev.posture
                    elseif net.mine[name] then
                        -- (This game runs it: what it loses is real, and the host's copy follows by its lines.)
                    elseif dHp > 0.5 and not net.pvp and not ownHit(actor) then
                        undoHit(actor, prev.hp, prev.posture)
                        hp, posture = prev.hp, prev.posture
                    else
                        local lethal = net.heldAlive[addr] ~= nil and dHp > 0.5 and hp <= HELD_HP + 0.01
                        reportHit(name, actor, math.max(0, dHp), math.max(0, dPosture), lethal)
                        if lethal then
                            log("Killing blow on " .. name .. "; telling the host.")
                        end
                    end
                end
            end
            local r = net.remoteEnemies[name]
            if r then
                -- One of the host's enemies: it dies when the host says so ("K"), never on its own here, so a
                -- killing blow is never played twice and a copy that's a hit ahead doesn't die before the host's.
                -- (Every turn, not once by address: a copy gone and a new one at its address was taken for held already, and
                -- died here on a hit, the host's alive.)
                if game.setMinHealth then
                    game.setMinHealth(actor, HELD_HP)
                end
                held[addr] = actor
                if api.puppets then
                    api.puppets.follow(name, actor, r)
                end
                if game.setMaxHealth and r.MaxHp and maxhp and math.abs(r.MaxHp - maxhp) > 1 then
                    game.setMaxHealth(actor, r.MaxHp)
                end
                if game.setHealth and r.Hp ~= nil and hp ~= nil and r.Hp < hp - 0.5 then
                    game.setHealth(actor, r.Hp)
                    hp = r.Hp
                end
                if game.setHealth and r.Hp ~= nil and hp ~= nil and r.MaxHp
                    and r.Hp > hp + math.max(1, r.MaxHp * 0.05) then
                    net.healTicks[name] = (net.healTicks[name] or 0) + 1
                    if net.healTicks[name] >= HEAL_TICKS then
                        log(string.format("%s healed on the host (%.0f -> %.0f): following.", name, hp, r.Hp))
                        game.setHealth(actor, r.Hp)
                        hp = r.Hp
                        net.healTicks[name] = nil
                    end
                else
                    net.healTicks[name] = nil
                end
                if game.setPosture and r.Posture ~= nil and posture ~= nil and r.Posture < posture - 0.5 then
                    game.setPosture(actor, r.Posture)
                    posture = r.Posture
                end
                net.stats.applied = net.stats.applied + 1
            end
            if net.mine[name] then
                handover.share(name, actor, addr)
            end
            nextSeen[name] = { hp = hp, posture = posture, addr = addr }
        elseif (net.hitHere[name] or net.mine[name]) and not net.hostKilled[name] and not net.guestKillSent[name] then
            -- It died here before the host had it loaded (we were far apart): the host's copy follows. In a party so does
            -- that of any guest near it. An enemy past the host's reach has no owner: it sleeps on the host, so each guest
            -- by it fights a copy of its own, as a guest alone does, and the first to kill it kills it for everyone.
            -- (Only one this player hit: a copy can read as dead for other reasons, and this would kill it everywhere. Or one
            -- this game ran for the host: its death was this game's own.)
            net.guestKillSent[name] = true
            sendEvent("GK", name)
        end
    end

    -- Host, each round: are the two apart, so that the guest's game may run what's clearly nearer the guest?
    function handover.update()
        local t = net.target
        if net.party or net.pvp or t == nil or net.ghostHidden or net.partnerGone or not sameMap(t) or net.localLoc == nil then
            handover.on = false
            return
        end
        handover.on = gap3d(net.localLoc, t) > (handover.on and handover.TOGETHER_CM or handover.APART_CM)
    end

    function handover.dist(x, y, z, o)
        return math.sqrt((x - o.X) ^ 2 + (y - o.Y) ^ 2 + (z - o.Z) ^ 2)
    end

    -- Host, an enemy's turn: true while the guest's game runs it. It's handed over, or taken back, as where it is says.
    function handover.guestRuns(name, actor, addr, x, y, z)
        local runs = net.guestRuns[name] == true
        if x == nil or x ~= x or y ~= y or z ~= z then
            return runs
        end
        local want = false
        if handover.on and name:sub(1, 3) == "sp:" and not (game.isBoss and game.isBoss(actor, addr)) then
            local dh, dg = handover.dist(x, y, z, net.localLoc), handover.dist(x, y, z, net.target)
            if runs then
                want = dh + handover.NEARER_CM >= dg
            else
                -- (Within the guest's own reach: its game has it near, and sends what it does.)
                want = dg <= ENEMY_RADIUS_CM and dg + handover.NEARER_CM < dh and os.clock() >= (handover.retryAt[name] or 0)
                    and not (dh <= handover.FIGHT_CM and game.enemyAfter(actor, net.ghost) == "host")
                    and not (game.isDead and game.isDead(actor))    -- (a body just gone can read as alive for a turn)
            end
        end
        if want ~= runs then
            handover.give(name, actor, addr, want)
        end
        return want
    end

    -- Host: the guest's game runs it from now on (on), or this one does again.
    function handover.give(name, actor, addr, on)
        if on then
            net.guestRuns[name] = true
            net.guestLines[name] = nil
            handover.seen[name] = nil
            handover.since[name] = net.frameNow
            log(name .. " is nearer the other player: their game runs it now.")
        else
            handover.release(actor, addr, name)
            log(name .. " is this game's to run again.")
        end
        sendEvent("RUN", name, on and 1 or 0)
    end

    -- Host: a copy the guest's game ran is this world's own again: held no more, its own AI back. It takes what the guest's
    -- game last said it had left first: out of this player's reach it had no turns to follow that, and came back with more.
    function handover.release(actor, addr, name)
        local r = net.guestLines[name]
        if r and valid(actor) and game.setHealth then
            local hp = game.getHealth(actor)
            if hp and r.Hp < hp - 0.5 then
                game.setHealth(actor, r.Hp)
            end
            local posture = game.getPosture and game.getPosture(actor)
            if game.setPosture and r.Posture and posture and r.Posture < posture - 0.5 then
                game.setPosture(actor, r.Posture)
            end
        end
        net.guestRuns[name], net.guestLines[name], handover.seen[name] = nil, nil, nil
        if net.heldAlive[addr] then
            net.heldAlive[addr] = nil
            if valid(actor) and game.setMinHealth then
                game.setMinHealth(actor, 0)
            end
        end
        if api.puppets then
            api.puppets.release(addr)
        end
    end

    -- Host: it died, whoever ran it. Nothing steers it now.
    function handover.drop(actor, addr, name)
        net.guestRuns[name], net.guestLines[name], handover.seen[name] = nil, nil, nil
        net.heldAlive[addr] = nil
        if api.puppets then
            api.puppets.drop(actor)
        end
    end

    -- Host, the turn of one the guest's game runs: this copy follows the guest's, as a guest's copies follow the host's, held
    -- at 1 health (it dies when the guest's does: GK), and this player's own hits on it go to the guest's game, where it
    -- lives. False: no word from the guest's game for a while, and it's this game's again from this turn.
    function handover.follow(name, actor, addr, hp, posture)
        local r = net.guestLines[name]
        if net.frameNow - (r and r.at or handover.since[name] or net.frameNow) > handover.QUIET_S then
            handover.retryAt[name] = os.clock() + handover.RETRY_S
            handover.give(name, actor, addr, false)
            return false
        end
        if r == nil then
            return true             -- (the guest's first line is on its way)
        end
        if game.setMinHealth then
            net.heldAlive[addr] = actor     -- (each turn: the actor at an address can be a new one, see syncEnemy)
            game.setMinHealth(actor, HELD_HP)
        end
        -- A drop since the last turn is weighed as a guest weighs one on its copies of the host's (syncEnemy).
        local prev = handover.seen[name]
        if prev and prev.addr == addr and prev.hp and hp then
            local dHp = prev.hp - hp
            local dPosture = (prev.posture and posture) and (prev.posture - posture) or 0
            if dHp > 0.5 or dPosture > 0.5 then
                if (ghostsHit() and dHp <= 0.5) or (dHp > 0.5 and not ownHit(actor)) then
                    undoHit(actor, prev.hp, prev.posture)
                    hp, posture = prev.hp, prev.posture
                else
                    local lethal = dHp > 0.5 and hp <= HELD_HP + 0.01
                    reportHit(name, actor, math.max(0, dHp), math.max(0, dPosture), lethal)
                    if lethal then
                        net.hostLethal[name] = true     -- (its items are rolled here when the death comes back: GK)
                    end
                end
            end
        end
        if api.puppets then
            api.puppets.follow(name, actor, r)
        end
        local _, maxhp = game.getHealth(actor)
        if game.setMaxHealth and maxhp and math.abs(r.MaxHp - maxhp) > 1 then
            game.setMaxHealth(actor, r.MaxHp)
        end
        if hp and r.Hp < hp - 0.5 then
            game.setHealth(actor, r.Hp)
            hp = r.Hp
        elseif hp and r.Hp > hp + math.max(1, r.MaxHp * 0.05) then
            net.healTicks[name] = (net.healTicks[name] or 0) + 1
            if net.healTicks[name] >= HEAL_TICKS then
                game.setHealth(actor, r.Hp)
                hp = r.Hp
                net.healTicks[name] = nil
            end
        else
            net.healTicks[name] = nil
        end
        if game.setPosture and r.Posture and posture and r.Posture < posture - 0.5 then
            game.setPosture(actor, r.Posture)
            posture = r.Posture
        end
        handover.seen[name] = { hp = hp, posture = posture, addr = addr }
        return true
    end

    -- Guest, the turn of one this game runs for the host: where it is and what it does go to the host's game, as the host's
    -- enemies come here.
    function handover.share(name, actor, addr)
        local x, y, z, yaw, vx, vy, _, _, hp, maxhp, posture = game.read(actor, addr)
        if hp and maxhp and maxhp > 0 and x == x and y == y and z == z and yaw == yaw then
            link.enemy(string.format("%d %.0f %.0f %.0f %.0f %.0f %.0f %.1f %.1f 0 %s", enemyNumber(actor, name),
                x, y, z, yaw, vx == vx and vx or 0, vy == vy and vy or 0, hp, maxhp,
                posture ~= nil and string.format("%.1f", posture) or "-"))
        end
        if api.puppets then
            api.puppets.watchHost(name, actor, addr)
        end
    end

    -- Everything handed over goes back: sync off or on again, the partner gone or started anew, a rest, another map.
    function handover.reset()
        if isHost() then
            for _, actor in pairs(net.heldAlive) do
                if valid(actor) and game.setMinHealth then
                    game.setMinHealth(actor, 0)
                end
            end
            net.heldAlive = {}
            if api.puppets then
                api.puppets.releaseAll()        -- (a host's puppets are only ever the ones a guest's game ran)
            end
        end
        net.guestRuns, net.guestLines, net.mine = {}, {}, {}
        handover.seen, handover.since, handover.retryAt, handover.on = {}, {}, {}, false
    end

    local function startHostRound(now)
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        handover.update()
        local queue, names = {}, {}
        for addr, e in pairs(reach.near) do
            if valid(e.actor) then
                queue[#queue + 1] = e
                -- (A live one over a body under the same id, as in shareEnemy.)
                local id = enemyName(e.actor, addr)
                local had = names[id]
                if not (had and not game.isDead(had) and game.isDead(e.actor)) then
                    names[id] = e.actor
                end
            else
                reach.near[addr] = nil
            end
        end
        -- One the guest's game ran that's out of reach now (the guest died, left, went far): it had no more turns, so it
        -- stood held at 1 health, its AI stopped, steered to the guest's last line, until the host came by. It's this game's.
        for name in pairs(net.guestRuns) do
            local actor = names[name] == nil and enemyByName[name]
            if actor ~= nil and actor ~= false then
                if valid(actor) then
                    handover.give(name, actor, actor:GetAddress(), false)
                else
                    net.guestRuns[name], net.guestLines[name], handover.seen[name] = nil, nil, nil
                    sendEvent("RUN", name, 0)
                end
            end
        end
        enemyByName = names
        round.queue, round.at, round.startedAt, round.number = queue, 1, now, round.number + 1
        round.aggro = now >= (round.aggroAt or 0)
        if round.aggro then
            round.aggroAt = now + AGGRO_S
            for _, p in ipairs(partners()) do
                if valid(p.ghost) and game.healGhost then
                    game.healGhost(p.ghost, net.pvp)
                end
            end
        end
    end

    -- Client: the host's enemies this world has no copy of, near this player. Kills last for good in a save, so a guest who has
    -- played further than the host has the early enemies long dead: the host fought what the guest couldn't see, and nothing
    -- there could hit the guest. Their spawners here bring them back (game.bringBack), a few a round. Bosses come with their
    -- fight (spawnBoss).
    local bring = {
        AFTER_S = 2.0,              -- unpaired this long first: a copy may just be loading in
        AGAIN_S = 10.0,             -- and asked again at most this often
        PER_ROUND = 2,              -- spawns cost a frame each
    }
    function bring.missing(now)
        for name in pairs(net.bringing) do
            if net.remoteEnemies[name] == nil or enemyByName[name] ~= nil then
                net.bringing[name] = nil
            end
        end
        local t = net.target
        if not (game.bringBack and t and not net.partnerGone and net.localLoc and t.Map == net.localMap) then
            return
        end
        local asked, back = 0, 0
        for name, r in pairs(net.remoteEnemies) do
            if enemyByName[name] == nil and not r.Boss and (r.Hp or 0) > 0 and name:sub(1, 3) == "sp:" and not net.hostKilled[name]
                and distance(net.localLoc, r) <= PARTNER_REACH_CM then
                local b = net.bringing[name] or { since = now, askedAt = -1e9 }
                net.bringing[name] = b
                if now - b.since >= bring.AFTER_S and now - b.askedAt >= bring.AGAIN_S and asked < bring.PER_ROUND then
                    b.askedAt = now
                    asked = asked + 1
                    local ok, wasDead = game.bringBack(name)
                    if ok then
                        back = back + 1
                        net.broughtBack[name] = wasDead or net.broughtBack[name]
                    end
                end
            end
        end
        if back > 0 then
            log(back .. " of the host's enemies weren't in your world: brought back while you play together.")
        end
    end

    -- Client: one of this world's own enemies near this player, by its id. The host's lines never pair one the host has
    -- dead, so a death told for it (BEATEN, or the host's dead as this player syncs) found nothing to kill: a boss the host
    -- had beaten stood on in the guest's world.
    function bring.own(name)
        for addr, e in pairs(reach.near) do
            if valid(e.actor) and enemyName(e.actor, addr) == name then
                return e.actor
            end
        end
        return nil
    end

    -- Client, each round: a death the host told before this world had the enemy loaded, for a copy of its own that has come
    -- since (the host's lines don't list a dead one, so it's never paired). Its own kill, as syncEnemy does for a paired one.
    function bring.pending()
        for name in pairs(net.pendingDeaths) do
            local own = enemyByName[name] == nil and bring.own(name)
            if own and not game.isDead(own) then
                net.pendingDeaths[name] = nil
                local boss = game.isBoss(own)
                game.kill(own)
                log("Host said " .. name .. " died earlier; killed it here now that it's loaded.")
                if boss then
                    -- (Its fight may have begun here: bar down and walls open, or the guest stood walled in.)
                    endBossFight(name, own)
                    bring.cardsLater()
                end
                if game.markBeaten then
                    game.markBeaten(name)
                end
            end
        end
    end

    -- Client: a boss ended here for a death in the host's world, maybe as its fight began: its reward's card can come up
    -- without its buttons (game.closeStuckCards). Looked at twice, a while after.
    function bring.cardsLater()
        if game.closeStuckCards then
            for _, s in ipairs({ 3, 6 }) do
                game.after(s, function() pcall(game.closeStuckCards, select(2, getPlayer1())) end)
            end
        end
    end

    -- Client: what bringBack turned back in this save's records goes back as it was.
    function bring.putBackAll()
        if game.putBack and next(net.broughtBack) then
            game.putBack(net.broughtBack)
        end
        net.broughtBack, net.bringing = {}, {}
    end

    local function startGuestRound(now)
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        -- (Not while the whole link is quiet: a second or two without packets, common over Radmin and the like, let every
        -- copy go to its own game at once, and they woke and fought this player by themselves until the host was heard
        -- again: "the enemy ... can still move, attack, and deal damage to me", issue #12. The partner gone is another way.)
        local linkQuiet = os.clock() - (net.lastRemoteAt or os.clock()) > ENEMY_STALE_S and not net.partnerGone
        -- (Nor in the second after it's back: the first packet is the player's, and the enemies' lines come over the next
        -- round, so every copy read as stale for a moment and woke between the two.)
        if linkQuiet then
            net.linkWasQuiet = true
        elseif net.linkWasQuiet then
            net.linkWasQuiet, net.linkBackAt = false, os.clock()
        end
        local settling = os.clock() - (net.linkBackAt or -1e9) < ENEMY_STALE_S
        for name, r in pairs((linkQuiet or settling) and {} or net.remoteEnemies) do
            if now - r.at > ENEMY_STALE_S then
                net.remoteEnemies[name] = nil
            end
        end
        -- The round that just ended: copies the host stopped sharing (it went out of range, or they're no longer
        -- matched) die normally again.
        if round.seen then
            seen = round.seen
            releaseHeld(round.held)
        end
        for addr, e in pairs(reach.near) do
            if not valid(e.actor) then
                reach.near[addr] = nil
            end
        end
        local own
        enemyByName, own = matchRemoteEnemies(reach.near)
        setAside(own, now)
        bring.missing(now)
        bring.pending()
        local queue = {}
        for name, actor in pairs(enemyByName) do
            queue[#queue + 1] = { name = name, actor = actor }
        end
        round.queue, round.at, round.startedAt, round.number = queue, 1, now, round.number + 1
        round.seen, round.held = {}, {}
    end

    local function enemyTurns(now, dt)
        local origin = net.localLoc
        if origin == nil then
            return
        end
        if isHost() then
            if net.party then
                updateReach(origin, nil, dt, guestsNear(origin))
            else
                local t = net.target
                local near = t ~= nil and not net.ghostHidden and gap3d(origin, t) <= PARTNER_REACH_CM
                updateReach(origin, near and t or nil, dt)
            end
            if round.at > #round.queue and now - round.startedAt >= ENEMY_ROUND_S then
                startHostRound(now)
            end
        else
            local t = net.target
            -- The host is on another map: its enemies aren't ours, so leave ours alone (and start hit tracking over).
            if t ~= nil and t.Map ~= nil and net.localMap ~= nil and t.Map ~= net.localMap then
                seen = {}
                round.seen, round.queue, round.at = nil, {}, 1
                releaseHeld(nil)
                showAside()
                if next(net.mine) then
                    net.mine = {}
                end
                return
            end
            updateReach(origin, nil, dt)
            if round.at > #round.queue and now - round.startedAt >= ENEMY_ROUND_S then
                startGuestRound(now)
            end
        end
        -- Whatever share of the round this frame stands for.
        local turns = math.ceil(#round.queue * math.max(dt, 0.004) / ENEMY_ROUND_S)
        for _ = 1, turns do
            local item = round.queue[round.at]
            if item == nil then
                return
            end
            round.at = round.at + 1
            if isHost() then
                if valid(item.actor) then
                    shareEnemy(item.actor, item.addr, round.aggro)
                end
            elseif valid(item.actor) then
                syncEnemy(item.name, item.actor, round.seen, round.held)
            end
        end
    end

    local function readEnemies(now)
        local text = link.enemies()
        if text == nil or net.partnerGone then
            return
        end
        -- A host hears of the ones a guest's game runs (handover). Each side takes only what the other runs: a line late
        -- from before a handover pulled a copy back for a moment.
        local into = isHost() and net.guestLines or net.remoteEnemies
        for line in text:gmatch("[^\n]+") do
            local n, x, y, z, yaw, vx, vy, hp, maxhp, boss, posture = line:match(
                "^(%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
            local who = n and net.enemyNames[tonumber(n)]
            if who and (isHost() and net.guestRuns[who.name] or (isClient() and not net.mine[who.name])) then
                local X, Y, Z, Yaw, Hp, MaxHp = num(x), num(y), num(z), num(yaw), num(hp), num(maxhp)
                -- Unparsable numbers or no health (MaxHp 0) would teleport or zero our copy: ignore the record.
                if X and Y and Z and Yaw and Hp and MaxHp and MaxHp > 0 then
                    -- The same table each time: puppets hold on to it and steer by the newest numbers.
                    local r = into[who.name] or { Class = who.class }
                    r.X, r.Y, r.Z, r.Yaw, r.Hp, r.MaxHp = X, Y, Z, Yaw, Hp, MaxHp
                    r.VX, r.VY = num(vx) or 0, num(vy) or 0
                    r.Boss, r.Posture, r.at = boss == "1", num(posture), now
                    into[who.name] = r
                end
            end
        end
    end

    -- Host: whose game runs this enemy now ("1": the guest's, which sends its lines and moves from now on; see handover).
    handlers.RUN = function(rest)
        local name, on = (rest or ""):match("^(%S+) ([01])$")
        if not name or isHost() or net.party then
            return
        end
        if on == "0" then
            -- (This game ran it: a death here from now on is sent as GK. A killing blow landed as RUN 0 came had nothing
            -- to send it, and the enemy lived on on the host.)
            if net.mine[name] then
                net.hitHere[name] = true
            end
            net.mine[name] = nil            -- (the host's lines take it from here, and pair it up again)
            return
        end
        net.mine[name] = true
        net.remoteEnemies[name] = nil
        local actor = enemyByName[name]
        if valid(actor) then
            local addr = actor:GetAddress()
            if net.heldAlive[addr] then
                net.heldAlive[addr] = nil
                game.setMinHealth(actor, 0)
            end
            if api.puppets then
                api.puppets.release(addr)   -- (its own AI back now, not when the host's lines run out)
            end
        end
    end

    handlers.N = function(rest)
        local n, name, class = rest:match("^(%d+) (%S+) (%S+)$")
        if n then
            net.enemyNames[tonumber(n)] = { name = name, class = class }
        end
    end

    -- The local enemy last paired with this host id, for a death that arrives after the host stopped listing it.
    local function stickyEnemy(name)
        local addr = net.matchSticky[name]
        if addr ~= nil and game.listEnemies then
            for _, e in ipairs(game.listEnemies()) do
                if valid(e) and e:GetAddress() == addr then
                    return e
                end
            end
        end
        return nil
    end

    handlers.GK = function(name)
        if isHost() and name then
            net.guestKilled[name] = true
        elseif name and net.party then
            net.guestKillSent[name] = true          -- another guest's kill, of an enemy the host doesn't run: see syncEnemy
            handlers.K(name)
        end
    end

    -- The partner has just (re)started sync: it knows nothing yet. It hears again what enemies are, and what's dead.
    handlers.S = function(_, from)
        log("The other player started sync.")
        peerOf(from).syncAt = os.clock()    -- (told all of it now: a retelling after their gap would only say it again)
        handover.reset()                    -- (what either game ran for the other, the other knows nothing of now)
        net.announced = {}
        net.enemyNames = {}
        net.lookSent = nil                  -- (what this player wears goes to them at the next look)
        net.bagSent, net.bagDue = false, os.clock() + 3     -- (and what's in this bag, once they're up: game.mergeBag)
        net.bagWaiting = nil                                -- (what they sent before is old now)
        -- (In a party, to that one guest: sent to all, every guest still in its first minute topped its bag up again at
        -- each join and each reconnect, the bombs and herbs it had used since.)
        if isHost() and from then
            net.bagTo = net.bagTo or {}
            net.bagTo[from] = true
        end
        if isHost() and game.offerChestsAgain then
            game.offerChestsAgain()         -- (the open chests here: named again, for them)
        end
        if isHost() and from then
            -- One guest of a party: the others know all this, and what's new to them is what that one holds.
            sendTo(from, "Y", hostWorld)
            for name in pairs(net.deadSent) do
                sendTo(from, "K", name)
            end
            net.tellBosses(from)
            net.fightToldAt = 0
            sendEvent("J", from)
        elseif isHost() then
            sendEvent("Y", hostWorld)
            for name in pairs(net.deadSent) do
                sendEvent("K", name)
            end
            net.tellBosses(nil)
            net.fightToldAt = 0
        else
            net.hostKilled = {}
            net.guestKillSent = {}
            net.hitHere = {}
        end
    end

    -- quiet: a death from before (BEATEN), not the end of a fight going on.
    handlers.K = function(name, _, quiet)
        local actor = enemyByName[name]
        if isClient() then
            net.hostKilled[name] = true
            net.remoteEnemies[name] = nil
            net.mine[name] = nil
            if not valid(actor) then
                actor = stickyEnemy(name)
            end
            if not valid(actor) then
                actor = bring.own(name)
            end
            local fought = net.hostBosses[name] or net.partnerBosses[name] or net.pendingBosses[name]
            local wasBoss = fought or (valid(actor) and game.isBoss and game.isBoss(actor))
            net.hostBosses[name] = nil
            if valid(actor) then
                if api.puppets then
                    api.puppets.drop(actor)
                end
                if game.isDead and game.isDead(actor) then
                    -- (Dead here first, by its own death: one this game ran (handover), whose death cut short looked wrong.)
                    log("Host says " .. name .. " died; it's dead here already.")
                elseif fought and not quiet and game.killForReal then
                    -- The boss of a fight both are in: the whole death here too, so this world's story goes on with the
                    -- host's, its scene after the fight first (a quiet kill skipped it, and the next phase came unseen).
                    game.killForReal(actor)
                    log("Host says " .. name .. " died; its death runs here too.")
                elseif not wasBoss and not quiet and game.dissolveKill then
                    game.dissolveKill(actor)            -- (it dissolves as a death does, paying nothing here)
                    log("Host says " .. name .. " died; it dies here too.")
                elseif game.kill then
                    game.kill(actor)
                    log("Host says " .. name .. " died; killed it here.")
                    if wasBoss then
                        bring.cardsLater()
                    end
                end
            else
                -- Not loaded (or not matched) here right now: kill it when it shows up (applyRemoteEnemies).
                net.pendingDeaths[name] = true
                log("Host says " .. name .. " died; not matched here yet, will kill it when it is.")
            end
            if net.broughtBack[name] then
                net.broughtBack[name] = nil
                game.putBack(name)              -- (dead in this save before: dead in it again)
            end
            if game.markBeaten then
                game.markBeaten(name)
            end
            if wasBoss then
                endBossFight(name, actor)
            end
        end
    end

    -- from: the slot of the guest who hit it, with more than two players, or nil. Where they are is peerOf(from).target, which
    -- with two players is net.target: anything that asks where "the guest" is must go by that, not by net.target, which in a
    -- host's party is only its first guest here.
    handlers.D = function(rest, from)
        local name, amount, posture, lethal = rest:match("^(%S+) (%S+)%s*(%S*)%s*(%S*)")
        -- Checked before anything else: a real number in range (the lethal flag below can't smuggle in more).
        amount = num(amount)
        if amount == nil or amount < 0 or amount > MAX_EVENT_DAMAGE then
            return
        end
        posture = num(posture)
        posture = posture and math.max(0, math.min(posture, MAX_EVENT_DAMAGE)) or 0
        if lethal == "L" then
            amount = math.huge      -- the client's killing blow (its copy can't show the full damage)
            log("Partner's killing blow on " .. tostring(name) .. (valid(enemyByName[name]) and "." or ", which isn't loaded here."))
        end
        -- The reaction the hit made on the sender's copy, played on the enemy itself (puppets.react). Only a hit state.
        local rpath, rpos, rtag = rest:match("^%S+ %S+ %S+ %S+ (%S+) (%S+) (%S+)$")
        rpos = num(rpos)
        if not (rtag and rtag:match("^CharacterState%.[%w%.]+$") and rtag:lower():find("hitreact", 1, true)
            and rpos and rpos >= 0 and rpos < 600 and #rpath <= 256) then
            rtag = nil
        end
        local function react(actor)
            if rtag and api.puppets and not (game.isDead and game.isDead(actor)) then
                api.puppets.react(name, actor, rpath, rpos, rtag)
            end
        end
        if isClient() and name and net.mine[name] then
            -- The host's hit on one this game runs (handover): it lands here, where the enemy lives. A killing blow is its
            -- whole death here, paying this player, and that dust reaches the host as any of this player's does.
            local actor = enemyByName[name]
            if valid(actor) and game.applyDamage and net.target and gap3d(actor:K2_GetActorLocation(), net.target) <= OWN_HIT_CM then
                game.applyDamage(actor, amount, posture, true)
                react(actor)
                local left = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                    addr = actor:GetAddress() }
                seen[name] = left           -- (a reported hit: its turn mustn't weigh it again, nor undo it)
                if round.seen and round.seen[name] then
                    round.seen[name] = left
                end
            end
        end
        -- (One the guest's game runs takes no hits here: its lines say what it has left.)
        if isHost() and name and not net.guestRuns[name] then
            local actor = enemyByName[name]
            local hitter = peerOf(from).target
            if valid(actor) and game.applyDamage and hitter
                and gap3d(actor:K2_GetActorLocation(), hitter) <= OWN_HIT_CM then
                local wasAlive = not (game.isDead and game.isDead(actor))
                local boss = net.partnerBosses[name] or (game.isBoss and game.isBoss(actor))
                local real = game.applyDamage(actor, amount, posture, true)
                game.partnerHit(actor:GetAddress(), from)
                react(actor)
                if wasAlive and (real or (game.isDead and game.isDead(actor))) then
                    if real and boss and game.rollLoot then
                        -- The game ran the whole death and paid this player, as for their own blow. A boss's items are
                        -- the client's too.
                        local _, items = game.rollLoot(actor)
                        local paid = {}
                        sendItems(name, items, paid)
                        if #paid > 0 then
                            log("Boss items for your partner too: " .. table.concat(paid, ", ") .. ".")
                        end
                    elseif not real and game.rollLoot then
                        payKillLoot(name, actor)
                    end
                    -- At once, not at the enemy's next turn: the partner is looking at a copy held at 1 health.
                    net.deadSent[name] = true
                    net.deadBodies[actor:GetAddress()] = true   -- (by the body too, as shareEnemy marks it: else a new enemy
                                                                -- under the id cleared the name, the old body told it again,
                                                                -- and a boss's items went out twice)
                    sendEvent("K", name)
                    if game.markBeaten then
                        -- (Its turn below won't see this death: deadSent is up already. A boss the guest finished came
                        -- back on the host's next load.)
                        game.markBeaten(name)
                    end
                    if boss then
                        endBossFight(name, actor)
                    end
                end
                net.stats.hitsApplied = (net.stats.hitsApplied or 0) + 1
                if net.hostSeen[name] then
                    -- A reported hit, not the ghost's: the PvP undo check must take this as the new baseline.
                    net.hostSeen[name] = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                        addr = actor:GetAddress() }
                end
                if seen[name] then
                    -- In "loop" mode the client half watches this same enemy: this drop isn't a new local hit.
                    seen[name] = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                        addr = actor:GetAddress() }
                end
            end
        end
    end

    ------------------------------------------------------------------ items

    -- What the game gave the partner. Played with nobody in the world (a map loading) it waits. So does what's shared by word.
    local giftsWaiting = {}
    local dustWaiting = 0

    handlers.I = function(rest)
        local name, itemId, kind = rest:match("^(%S+)%s*(%S*)%s*(%S*)")
        -- (Every way on gets the same limits: the item went to the backpack unchecked when this player was there.)
        if name and game.takeRemotePickup and #name <= MAX_CHEST_NAME and #itemId <= MAX_ITEM_NAME and #kind <= 16 then
            local _, pawn = getPlayer1()
            kind = (kind ~= "" and kind ~= "-") and kind or nil
            if valid(pawn) or name:sub(1, 5) ~= "loot:" then
                game.takeRemotePickup(name, itemId, pawn, kind)
            else
                giftsWaiting[#giftsWaiting + 1] = { id = itemId, count = 1, kind = kind, loot = true }
            end
        end
    end

    handlers.O = function(name)
        if name and #name <= MAX_CHEST_NAME and game.partnerOpened then
            game.partnerOpened(name)
        end
    end

    handlers.T = function(rest, from)
        local id, count, kind = rest:match("^(%S+) (%d+) (%S+)$")
        count = num(count)
        if id and #id <= MAX_ITEM_NAME and #kind <= 16 and count and count >= 1 and count <= MAX_GIFT then
            giftsWaiting[#giftsWaiting + 1] = { id = id, count = count, kind = kind ~= "-" and kind or nil, from = from }
        end
    end

    -- The bags, on linking (see game.mergeBag): the host sends what it has once per link, in lines a few hundred
    -- characters long, and a guest takes from it what it lacks, at a moment with a body to put it on. Only the host
    -- gives (the user's rule, after a report): a guest catches up to the host's world, boss weapons the story needs
    -- included, but a guest far ahead (a finished NG+ save) gave a newcomer host everything, and spoiled their game.
    do      -- (a block of its own: this function is at the 200 locals Lua allows)
    local BAG_LINE = 600
    function net.sendBag()
        if not isHost() then
            net.bagSent = true      -- (a guest's bag is its own: nothing goes to the host)
            return true
        end
        local _, pawn = getPlayer1()
        if not (game.bagSummary and valid(pawn)) or game.isDead(pawn) then
            return false
        end
        local list, line, lines = game.bagSummary(pawn), {}, 0
        local size = 0
        local to = net.party and net.bagTo and next(net.bagTo) and net.bagTo or nil
        local function send(text)
            if to then
                for slot in pairs(to) do
                    sendTo(slot, "BAG", text)
                end
            else
                sendEvent("BAG", text)
            end
        end
        for _, e in ipairs(list) do
            if size + #e + 1 > BAG_LINE and #line > 0 then
                send(table.concat(line, ","))
                line, size, lines = {}, 0, lines + 1
            end
            line[#line + 1], size = e, size + #e + 1
        end
        if #line > 0 then
            send(table.concat(line, ","))
            lines = lines + 1
        end
        net.bagSent, net.bagTo = true, nil
        log(string.format("Sent what's in this bag (%d things, %d lines): the partner takes what they lack.", #list, lines))
        return true
    end
    handlers.BAG = function(rest, from)
        -- (The host's bag only: a host takes nothing, and in a party a guest takes nothing from another guest.)
        if isHost() or from ~= nil or type(rest) ~= "string" or #rest > BAG_LINE + 80 then
            return
        end
        net.bagWaiting = net.bagWaiting or {}
        for e in rest:gmatch("[^,]+") do
            if #e <= MAX_ITEM_NAME + 12 and e:match("^[wemap]:[%w_%-]+:%d+$") and #net.bagWaiting < 4000 then
                net.bagWaiting[#net.bagWaiting + 1] = e
            end
        end
        if not net.bagSent then
            net.bagDue = 0          -- (they've sent theirs: ours goes too, if it hasn't this link)
        end
    end
    extraTicksEarly.bags = function()
        if not net.enabled then
            return
        end
        local now = os.clock()
        if net.bagDue and now >= net.bagDue and net.sendBag() then
            net.bagDue = nil
        end
        local waiting = net.bagWaiting
        local _, pawn = getPlayer1()
        if waiting and valid(pawn) and not game.isDead(pawn) and not (game.inCutscene and game.inCutscene()) and game.mergeBag then
            net.bagWaiting = nil
            -- (Counts once a game run: what's used up since stays used. A big bag comes in several lines, and those can come
            -- a tick or more apart: all that come in the first minute are counted, or only the first line's were.)
            net.bagCounted = net.bagCounted or now + 60
            local came = game.mergeBag(pawn, waiting, now < net.bagCounted)
            if came > 0 then
                log(string.format("Took %d things from the partner's bag that this one lacked.", came))
                api.status.notify("bag", string.format("your bag now has what your partner's has (%d new).", came))
            end
        end
    end
    end

    -- (No tip for them: the user didn't want "your partner found something" on screen. The log says what came.)
    local function takeGifts(pawn)
        for _, gift in ipairs(giftsWaiting) do
            if gift.loot then
                game.grantLoot(pawn, gift.id, gift.kind)
            else
                game.receiveGift(pawn, gift.id, gift.count, gift.kind, net.party and (gift.from or 1) or nil)
            end
        end
        giftsWaiting = {}
        if dustWaiting > 0 and game.addCurrency then
            game.addCurrency(pawn, dustWaiting)
            dustWaiting = 0
        end
    end

    local function reportChest(name)
        log("Opened " .. name .. ": telling the other player.")
        sendEvent("O", name)
    end

    -- The host's world decides (FollowHostStory): a chest the host opened before, alone, is opened for a guest too, and pays
    -- them what it holds there, so both have the same things. The host names the open chests it has loaded (OC).
    local function offerChest(name)
        sendEvent("OC", name)
    end

    handlers.OC = function(name)
        if isClient() and type(name) == "string" and #name <= MAX_CHEST_NAME and api.story and api.story.follow
            and game.hostOpened then
            game.hostOpened(name)
            net.chestsSoon = true           -- (looked at the next tick, before the player can open it themselves)
        end
    end

    -- A kick-stone another player kicked away: open here too, its boulder where theirs came to rest.
    handlers.KS = function(rest)
        local name, x, y, z, pitch, yaw, roll = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        x, y, z, pitch, yaw, roll = num(x), num(y), num(z), num(pitch), num(yaw), num(roll)
        -- (In the world: "1e30" is a number, and a boulder put there.)
        if name and #name <= MAX_CHEST_NAME and x and y and z and pitch and yaw and roll and game.stoneKicked
            and math.abs(x) < 1e7 and math.abs(y) < 1e7 and math.abs(z) < 1e7 then
            game.stoneKicked(name, { X = x, Y = y, Z = z }, { Pitch = pitch, Yaw = yaw, Roll = roll })
            log("The other player kicked " .. name .. " away: here too.")
        end
    end

    -- An effect another player's item showed on their body (a drink from the gourd): on their figure here too.
    handlers.FX = function(rest, from)
        local path, socket = (rest or ""):match("^(%S+) (%S+)$")
        local p = peerOf(from)
        if path and valid(p.ghost) and not p.ghostHidden and game.ghostEffect then
            game.ghostEffect(p.ghost, path, socket)
        end
    end

    -- What another player wears: their figure here is dressed in it (now, and when it's made anew).
    handlers.LOOK = function(rest, from)
        local outfit, hidden, skin = (rest or ""):match("^([%w_]+) ([01]) (%d+)$")
        if not outfit or #outfit > 64 then
            return
        end
        local p = peerOf(from)
        p.look = { outfit, hidden == "1", tonumber(skin) }
        if valid(p.ghost) and game.dressGhost and game.dressGhost(p.ghost, outfit, hidden == "1", tonumber(skin)) then
            log("The other player wears " .. outfit .. (hidden == "1" and " (hat off)" or "") .. ": their figure here too.")
        end
    end

    local function sendGift(id, count, kind)
        sendEvent("T", id, count, kind)
    end

    local function reportPickup(name, itemId)
        log("Picked up " .. name .. " (" .. tostring(itemId) .. "), telling the other player.")
        sendEvent("I", name, "?")       -- (only that it's gone: the item itself goes by T, like everything the game gives)
    end

    ------------------------------------------------------------------ bells and currency

    handlers.H = function(tag, from)
        local ghost = peerOf(from).ghost
        if valid(ghost) and game.playHitReaction and tag and tag ~= "" then
            game.playHitReaction(ghost, tag)
        end
    end

    -- A world refreshed: every boss fight can happen again. After a death the dead mostly stay dead, so a guest goes on by what
    -- the host killed, or what it never saw die there comes alive here alone. Only a new world ("bell": the host loaded its
    -- world again, or a mod's respawns) starts from nothing.
    -- whose: in a party, the guest whose rest it was. Only their fights end: one another player is in goes on, its bar and
    -- walls with it (a third player's bell rest took them down, and its B, told once, never put them back).
    local function forgetDeaths(kind, elsewhere, whose)
        -- (Only when this world's enemies came back. A rest elsewhere, or one during this player's own boss fight, left
        -- them dead here: wiped, the host never told them again (their bodies were marked told), not to anyone joining
        -- either, and a guest met them alive.)
        -- (The host's records only. A guest forgets the host's kills at any rest it hears of, as before: the host's world
        -- refreshed even when this guest is elsewhere, and kept, they killed its own copies as they loaded.)
        if kind ~= "death" and (not elsewhere or not isHost()) then
            if not elsewhere then
                net.deadSent = {}
                net.guestKilled = {}
            end
            net.guestKillSent = {}
            net.hostKilled = {}
        end
        net.pendingDeaths = {}
        for name in pairs(net.hostKilled) do
            net.pendingDeaths[name] = true
        end
        if whose then
            endFights(whose)
            game.forgetFocus()
            game.forgetMoves()
            handover.reset()
            return
        end
        net.pendingBosses = {}
        net.partnerBosses = {}
        net.hostBosses = {}
        net.hitHere = {}
        net.fightOf = {}
        net.notOnHost = {}
        net.bossAsk = {}
        net.joinedBoss, net.joinedWith, net.farFight = nil, nil, nil
        reopenFog()
        if game.resetBosses and not elsewhere then
            game.resetBosses()
        end
        game.forgetFocus()
        game.forgetMoves()
        handover.reset()
    end

    -- A death respawn refreshes the dying player's own world (the game does that, as in single-player).
    --   Host died: its world is everyone's truth, so the client's world refreshes too ("R death"): like the host
    --     dying in Elden Ring co-op, the fight starts over for both.
    --   Client died: only the client's world refreshed. The host's world, and its boss fight, go on untouched;
    --     the client's copies of what the host already killed are killed again, and a boss fight the host is
    --     still in is shown again (bar and fog walls).
    local restListeners = {}   -- name -> function(kind): a bell or death rest, here or the partner's (revive.lua)

    local function restEvent(kind)
        for _, fn in pairs(restListeners) do
            fn(kind)
        end
    end

    local function onLocalRest(kind)
        -- (A guest's own death refreshes only its own world: the host's enemies, and their twins, go on.)
        net.restRefreshes = isHost()
        restEvent(kind)
        if kind == "death" and net.role == "client" then
            log("You died and respawned: your world refreshed, the host's goes on. Enemies the host already killed stay dead.")
            local again = 0
            for name in pairs(net.hostKilled) do
                net.pendingDeaths[name] = true
                again = again + 1
            end
            -- (Only while the host's fight is on: one the host never joined, or walked out of, came back as a bar and shut
            -- walls with nobody's fight behind them.)
            if (net.party and peerOf(nil).fights) or (not net.party and net.partnerFighting) then
                for name in pairs(net.hostBosses) do
                    net.pendingBosses[name] = true
                end
            end
            reopenFog()
            if game.resetBosses then
                game.resetBosses()
            end
            seen = {}
            releaseHeld(nil)
            -- (And the round under way with it: its end put back what it had held as held, with the floor gone, so the
            -- floor was never set again and host enemies died here on this player's own hits.)
            -- (Its queue too, all of it: the turns left in it went on with the list taken away, an error each one.)
            round.seen, round.held, round.queue, round.at = nil, {}, {}, 1
            net.mine = {}       -- (this world's enemies are new ones: what it ran for the host, the host takes back unheard of)
            if again > 0 then
                log(again .. " enemies the host killed will be removed again as they load.")
            end
            return
        end
        if kind == "death" then
            log("You died as host: enemies respawn in both worlds (the host's world is the shared one).")
        else
            log("Rested at a bell (enemies respawned): telling the other player.")
        end
        forgetDeaths(kind)
        sendEvent("R", kind)
    end

    -- The bosses of a fight of this player's own, alive: not copies of another player's fight.
    function net.ownBosses()
        local own = {}
        for _, actor in ipairs(game.bossActors and game.bossActors() or {}) do
            local mirrored = false
            for name in pairs(net.partnerBosses) do
                mirrored = mirrored or enemyByName[name] == actor
            end
            if not mirrored and valid(actor) and not game.isDead(actor) then
                own[#own + 1] = actor
            end
        end
        return own
    end

    -- The host's fights going on, told again: B goes once, as a fight starts, and a guest who started sync again or came
    -- back from a gap (their fights ended then) saw no bar and no walls for the rest of it. slot: one guest of a party.
    function net.tellBosses(slot)
        if not isHost() then
            return
        end
        for _, actor in ipairs(net.ownBosses()) do
            if slot then
                sendTo(slot, "B", enemyName(actor))
            else
                sendEvent("B", enemyName(actor))
            end
        end
    end

    handlers.R = function(kind, from)
        peerOf(from).fights = false     -- (that player's fight is over, and a bar left up there can't say so yet)
        countFights()
        -- From another map it says nothing about the enemies here, or the fight this player may be in.
        local elsewhere = not sameMap(peerOf(from).target)
        -- Nor, at a bell, about a boss fight of this player's own (not a copy of one of theirs): a partner resting isn't in it.
        -- Its bar came down and every monster came back mid-fight. (A host's death is everyone's: that one ends it.)
        local ownFight = kind ~= "death" and not elsewhere and #net.ownBosses() > 0
        elsewhere = elsewhere or ownFight
        -- (Said before the listeners hear it: whether this world's enemies come back, which is what the twins go by.)
        -- (On a guest, the host's own word only: another guest's rest, passed on, says nothing of whether the host's world
        -- refreshed, and twins taken away then could never come back here.)
        net.restRefreshes = not elsewhere and (isHost() or from == nil)
        restEvent(kind)
        if kind == "death" then
            log("The host died and respawned: enemies respawn here too.")
        else
            log("The other player rested at a bell: respawning enemies here too.")
        end
        if ownFight then
            log("A boss fight of your own is on: it goes on, and enemies here come back at the next rest.")
        end
        forgetDeaths(kind, elsewhere, net.party and from or nil)
        seen = {}
        if game.refreshEnemies and not elsewhere then
            game.refreshEnemies()
        end
    end

    -- A sit at a bell is everyone's: whoever's dead, down or watching comes to the one who sat, and anyone else is rested where
    -- they stand. It says the sitter's fight is over too, or a bar left up there would hold a partner's respawn for good.
    local function onLocalSit()
        restEvent("sit")
        if game.resetBosses then
            game.resetBosses()
        end
        net.fightHereAt = nil
        log("Sat at a bell: telling the other player.")
        sendEvent("SIT")
    end

    handlers.SIT = function(_, from)
        local p = peerOf(from)
        p.fights = false
        countFights()
        restEvent("sit")
        endFights(net.party and p.number or nil)
        local _, pawn = getPlayer1()
        if net.pvp or not valid(pawn) then
            return
        end
        local who = net.party and PLAYERS[p.number].name or "your partner"
        if game.isDead(pawn) or net.watchingFight then
            if not net.partnerFighting then       -- (with more than two, someone else's fight can still be on)
                api.partner.comeTo(p)
                api.status.notify("rest", who .. " rested at a bell: you'll join them.")
            end
        else
            game.restHere(pawn)
            -- In a boss fight of one's own, the boss is rested too, back to full health (the user's rule): the rest is no free
            -- heal in the middle of a fight, with the partner sitting down for it on purpose.
            local bosses = net.ownBosses()
            for _, boss in ipairs(bosses) do
                local _, maxhp = game.getHealth(boss)
                if maxhp and maxhp > 0 and game.setHealth then
                    game.setHealth(boss, maxhp)
                end
            end
            if #bosses > 0 then
                log("The other player sat at a bell during your boss fight: you're rested, and so is the boss.")
                api.status.notify("rest", who .. " rested at a bell: you're rested, and so is the boss.")
            else
                api.status.notify("rest", who .. " rested at a bell: you're rested too.")
            end
        end
        log("The other player sat at a bell.")
    end

    -- The host's world is everyone's truth. Loaded anew (it restarted, or left to the title screen and came back) it has
    -- everything alive again, so this world refreshes too, or what died here would stay alive there and unseen here.
    handlers.Y = function(world)
        local known = net.hostWorld
        net.hostWorld = world
        if known ~= nil and known ~= world then
            log("The host loaded its world again.")
            handlers.R("bell")
        end
    end

    -- The host's world is everyone's truth, and a boss beaten there is beaten: a guest whose save still has it (a save from
    -- before, or one 1.5.1 didn't write the kill into) fought it alone behind its walls, and the host saw them swing at nothing.
    local function tellBeaten(name, from)
        if from then
            sendTo(from, "BEATEN", name)
        else
            sendEvent("BEATEN", name)
        end
        log("The other player's " .. name .. " is beaten here: telling them.")
    end

    -- A guest asks after an enemy of its own. Anything loaded here counts, however far from this player: only "no" is sent.
    handlers.HAS = function(name, from)
        if not isHost() then
            return
        end
        local list, addrs = game.listEnemies()
        for i, actor in ipairs(list) do
            if valid(actor) and enemyName(actor, addrs[i]) == name and not game.isDead(actor) then
                return
            end
        end
        if game.isBeaten and game.isBeaten(name) then
            tellBeaten(name, from)
        elseif from then
            sendTo(from, "NOT", name)
        else
            sendEvent("NOT", name)
        end
    end

    handlers.NOT = function(name)
        net.notOnHost[name] = true
    end

    handlers.C = function(amount)
        amount = num(amount)
        if amount and amount > 0 and amount <= MAX_EVENT_DUST then
            dustWaiting = dustWaiting + amount
        end
    end

    ------------------------------------------------------------------ bosses

    -- side: how far off the spot to land. (Beside a boss, not on it. On a partner it's fine: the ghost ignores pawns.)
    local function arriveAt(pawn, at, side)
        pawn.CharacterMovement:SetMovementMode(MOVE_FLYING, 0)
        local spot = { X = at.X + (side or BOSS_JOIN_SIDE_CM), Y = at.Y, Z = at.Z + 100 }
        pawn:K2_SetActorLocation(spot, false, {}, true)
        net.arriveUntil = os.clock() + ARRIVE_HOLD_S
        net.arrival = net.arrival or { spot = spot, untilClock = os.clock() + ARRIVE_WATCH_S }
    end

    -- A boss fight on the other PC: the same boss here, and walls closed around it. Nobody is brought in: a player who
    -- wants to fight alone can, and the other joins by choice, E at the black wall, or F3 for an arena apart from the
    -- map (see fogPress, joinFarFight).
    local function joinBossFight(name, p)
        local _, pawn = getPlayer1()
        -- (Another guest's fight, on a guest: only the host's world can say the boss lives, so one this save has beaten
        -- isn't brought back for it. The host tells everyone if it's beaten there.)
        local at, turned = nil, false
        if game.spawnBoss then
            at, turned = game.spawnBoss(name, not (isClient() and p ~= net))
        end
        if turned and isClient() then
            -- (Written alive in this save for the host's fight: dead again when the session ends, unless the host's kill
            -- makes it beaten for real. It stayed alive here for good when the host lost, rested or left.)
            net.broughtBack[name] = true
        end
        if not at and sameMap(p.target) then
            at = p.target
        end
        if game.refreshEnemyIds then
            game.refreshEnemyIds(true)
        end
        if not at or not valid(pawn) or game.isDead(pawn) or p.ghostHidden == nil then
            return
        end
        if gap3d(pawn:K2_GetActorLocation(), at) > BOSS_JOIN_CM then
            net.farFight = { name = name, p = p, at = { X = at.X, Y = at.Y, Z = at.Z } }
            api.status.notify("join", "your partner is in a boss fight: F3 takes you there, if you want to join.")
        else
            net.farFight = nil
            api.status.notify("join", "your partner is in a boss fight: press E at the black wall to join.")
        end
    end

    -- F3 during a partner's fight in an arena apart from the map. True if it took this player there. (Not TP > PARTNER:
    -- there's no other way in.)
    local function joinFarFight()
        local far = net.farFight
        local _, pawn = getPlayer1()
        if not (far and net.partnerBosses[far.name] and valid(pawn)) or game.isDead(pawn) then
            return false
        end
        net.farFight = nil
        log("Joining the other player's boss fight, in an arena apart from the map.")
        net.joinedBoss, net.joinedWith, net.joinedFar = far.name, far.p, true
        net.arrival = nil
        arriveAt(pawn, far.at)
        return true
    end

    do      -- (a block of its own: this function is at the 200 locals Lua allows)
    local FOG_PRESS_CM = 1000     -- how close to a closed fog wall E takes you through it, into the partner's fight

    -- Whether a boss fight here is this player's own (its walls keep them in), not one mirrored from a partner.
    local function ownBossFight()
        for _, actor in ipairs(game.bossActors and game.bossActors() or {}) do
            local mirrored = false
            for name in pairs(net.partnerBosses) do
                mirrored = mirrored or enemyByName[name] == actor
            end
            if not mirrored then
                return true
            end
        end
        return false
    end

    -- E (or the pad's interact) at a closed fog wall, during a partner's boss fight on this map, with that partner on the
    -- far side: through it. Never out of a fight: the walls are there to keep its players in.
    local function fogPress()
        local controller, pawn = getPlayer1()
        local down = net.partnerFighting and next(net.partnerBosses) ~= nil and valid(pawn)
            and (controller:IsInputKeyDown({ KeyName = FName("E") })
                or controller:IsInputKeyDown({ KeyName = FName("Gamepad_FaceButton_Right") }))
        local pressed = (down and not net.fogKeyDown) or net.fogPressAsked
        net.fogKeyDown, net.fogPressAsked = down, nil     -- (asked: the "walljoin" command, as a press of E)
        if not pressed or not valid(pawn) or game.isDead(pawn) or net.joinedBoss or ownBossFight() or not game.closedFogNear then
            return
        end
        local here = pawn:K2_GetActorLocation()
        local wall = game.closedFogNear(here, FOG_PRESS_CM)
        if not wall then
            return
        end
        for name in pairs(net.partnerBosses) do
            local p = net.party and peerOf(net.fightOf[name]) or net
            local inside = (sameMap(p.target) and p.target) or (valid(enemyByName[name]) and enemyByName[name]:K2_GetActorLocation())
            if inside and (game.fogSide(wall, here) >= 0) ~= (game.fogSide(wall, inside) >= 0) then
                if game.passFog(pawn, wall, inside) then
                    log("Through the fog wall, into the other player's boss fight.")
                    net.joinedBoss, net.joinedWith, net.joinedFar = name, p, false
                else
                    api.status.notify("join", "no ground past the wall here: try another part of it.")
                end
                return
            end
        end
    end
    extraTicksEarly.fogPress = function()
        local ok, err = pcall(fogPress)
        if not ok then
            log("Fog wall key error: " .. tostring(err))
        end
    end
    end

    -- With more than two players, who F3 goes to: the nearest on this map who's up. If nobody is, a guest goes to the host
    -- and a host to its first guest who's up: those are the maps the relay can name. Nil with two players, or nobody to go to.
    local function nearestPartner()
        if not net.party then
            return nil
        end
        local from, best, bestGap, elsewhere = net.localLoc, nil, math.huge, nil
        for _, p in ipairs(partners()) do
            local t = p.target
            if t and not p.partnerGone and t.Hp and t.Hp > 0 and not t.Cine then
                if from and t.Map == net.localMap then
                    local d = gap3d(from, t)
                    if d < bestGap then
                        best, bestGap = p, d
                    end
                else
                    elsewhere = elsewhere or p
                end
            end
        end
        return best or elsewhere
    end

    -- This player goes to the partner, on this map or another: a friend on a new save could never walk to a host deep in
    -- the story, and a door only the other world has opened would keep them apart. Says why not, or nil once on the way.
    -- p: who, in a party (no one named: the host, or the host's first guest here).
    local function joinPartner(p)
        p = p or net
        local controller, pawn = getPlayer1()
        local t = p.target
        if not (net.enabled and t and valid(pawn)) or p.partnerGone or p.ghostHidden == nil then
            return "no partner to go to yet."
        end
        -- (Someone who's been watching a fight that's over can still have its bar up here. It goes with the trip.)
        if game.isDead(pawn) or (game.inCutscene and game.inCutscene()) or net.pvp or (game.bossFightActive() and not net.watchingFight)
            or api.gs():IsGamePaused(controller) or api.localcoop.bellMenuUp() or api.localcoop.screenUp() then
            return "not now."
        end
        if t.Hp == nil or t.Hp <= 0 or t.Cine then
            return "your partner can't be joined right now."
        end
        if os.clock() < (net.travelUntil or 0) then
            return nil              -- (on the way already: a second press in the loading screen began the trip again)
        end
        if not (math.abs(t.X) < 1e7 and math.abs(t.Y) < 1e7 and math.abs(t.Z) < 1e7) then
            return "your partner's position looks wrong."
        end
        if t.Map == net.localMap then
            local gap = gap3d(pawn:K2_GetActorLocation(), t)
            -- Far off on this map, the ground there isn't loaded: the game's own trip, as a bell's fast travel, with its
            -- loading screen, sets the player down once it is (15 s on Xigu, landed walking to the centimetre). Near, a
            -- hop: that ground is loaded already. (The user: "pause them or load them since they could teleport to host on a
            -- different location that is not loaded".)
            local level = gap > 20000 and game.travel and game.mapName and game.mapName(pawn)
            if level and level ~= "?" and game.travel(level, t) then
                net.travelUntil = os.clock() + 30
                log(string.format("Going to the other player, %.0f m off: by the game's own trip.", gap / 100))
            elseif gap > JOIN_NEAR_CM then
                net.arrival = nil       -- (this trip's spot, not the last one's)
                arriveAt(pawn, t, 0)
            end
            return nil
        end
        local level = (link.status() or ""):match((p.number and p ~= net) and (" map" .. p.number .. "=(%S+)") or "partner_map=(%S+)")
        if not level or level == "-" or level == "?" then
            return "your partner's map isn't known yet."
        end
        if not (game.travel and game.travel(level, t)) then
            return "the game wouldn't go there."
        end
        net.travelUntil = os.clock() + 30
        log("Going to the other player, on " .. level .. ".")
        return nil
    end

    local function watchArrival()
        if not (net.arriveUntil or net.arrival or net.bossOverAt) then
            return
        end
        local _, pawn = getPlayer1()
        if net.arriveUntil and os.clock() >= net.arriveUntil then
            net.arriveUntil = nil
            net.landedCheckAt = os.clock() + ARRIVE_SETTLE_S
            if valid(pawn) then
                pawn.CharacterMovement:SetMovementMode(MOVE_WALKING, 0)
            end
        end
        local arrival = net.arrival
        if arrival then
            -- (Once dead, the next drop in height is a respawn at a bell, not ground that hasn't loaded: taken for one, it
            -- put the respawned player back in the arena.)
            if os.clock() >= arrival.untilClock or not valid(pawn) or game.isDead(pawn) then
                net.arrival = nil
            elseif not net.arriveUntil and pawn:K2_GetActorLocation().Z < arrival.spot.Z - ARRIVE_FALL_CM then
                log("The ground isn't loaded yet: holding a little longer.")
                pawn.CharacterMovement:SetMovementMode(MOVE_FLYING, 0)
                pawn:K2_SetActorLocation(arrival.spot, false, {}, true)
                net.arriveUntil = os.clock() + ARRIVE_HOLD_S
            elseif not net.arriveUntil and os.clock() >= (net.landedCheckAt or 0)
                and pawn.CharacterMovement.MovementMode == MOVE_WALKING then
                net.arrival = nil       -- on the ground: from here a drop is a slope or a ledge, and the player's own
            end
        end
        -- The boss is dead and the partner has gone back to the map: don't leave this player stranded in the arena.
        if net.bossOverAt and os.clock() >= net.bossOverAt then
            net.bossOverAt = nil
            local t = (net.joinedWith or net).target
            if valid(pawn) and sameMap(t) and not game.isDead(pawn) and gap3d(pawn:K2_GetActorLocation(), t) > BOSS_JOIN_CM then
                arriveAt(pawn, t)
            end
        end
    end
    extraTicksEarly.arrival = watchArrival

    -- A partner heard from a moment ago.
    local LINKED_S = 5.0
    -- (Any of them, in a party: net is only the lead there, and one guest in a loading screen stopped the host's story for
    -- every guest, their quest steps' baselines wiped.)
    local function linked()
        if not net.enabled then
            return false
        end
        for _, p in ipairs(partners()) do
            if not p.partnerGone and p.lastRemoteAt ~= nil and os.clock() - p.lastRemoteAt < LINKED_S then
                return true
            end
        end
        return false
    end

    -- Never paused with a partner linked: their game goes on, so a menu here is a menu in a live world, as in any co-op.
    extraTicksEarly.noPause = function()
        if linked() then
            local controller, pawn = getPlayer1()
            if valid(pawn) and api.gs():IsGamePaused(controller) then
                api.gs():SetGamePaused(controller, false)
            end
        end
    end

    handlers.BEATEN = function(name)
        if not isClient() or type(name) ~= "string" or #name > MAX_ITEM_NAME then
            return
        end
        log("The host has beaten " .. name .. ": beaten here too.")
        net.hostBosses[name] = true        -- (so that the kill below ends the fight here: bar down, walls open)
        handlers.K(name, nil, true)
    end

    handlers.B = function(name, from)
        if isHost() and game.isBeaten and game.isBeaten(name) then
            tellBeaten(name, nil)       -- (to everyone: the relay gave the other guests this fight too)
            return
        end
        log("The other player started a boss fight with " .. name .. ".")
        -- (The host's word only. Another guest's fight, passed on by the relay, isn't the host's: taken for it, it stayed
        -- the host's fight here for good, and came back as walls and a bar after this player's next death.)
        local fromHost = net.role == "client" and from == nil
        if fromHost and net.hostBosses[name] and net.partnerBosses[name] then
            return                          -- (told again, and shown here already)
        end
        if fromHost then
            -- The host has it alive and is fighting it, whatever this session last heard (their world loaded again, say): a copy
            -- brought back for the fight would be killed on sight as the host's old kill.
            net.hostKilled[name] = nil
            net.pendingDeaths[name] = nil
        end
        net.partnerBosses[name] = true
        if net.party then
            net.fightOf[name] = from or 1
        end
        joinBossFight(name, peerOf(from))
        if fromHost then
            net.hostBosses[name] = true
        end
        local actor = enemyByName[name]
        if valid(actor) and not game.isDead(actor) then
            mirrorBossFight(name, actor)
        else
            -- Not known here yet (spawning, still loading, or too far from the host's copy): mirror it once it is.
            -- (A corpse goes by the same id: mirrored, it closed the fog walls around a dead boss.)
            net.pendingBosses[name] = true
            log("Boss " .. name .. " isn't here yet; will show its fight when it is.")
        end
    end

    -- The game started a boss fight here, and the other PC shows it too. A client's copy goes by the host's id. A boss
    -- the partner's fight spawned here registers by itself: that's their fight coming back, not news.
    local function announceBoss(actor)
        local addr, name = actor:GetAddress(), enemyName(actor)
        for id, e in pairs(enemyByName) do
            if valid(e) and e:GetAddress() == addr then
                name = id
                break
            end
        end
        if isClient() and net.hostKilled[name] then
            -- The host has beaten this boss: this copy came back with our own respawn. It stays dead, and no fight starts.
            game.after(0.1, function()
                if valid(actor) then
                    game.kill(actor)
                    game.hideBossBar(actor)
                end
                if game.markBeaten then
                    game.markBeaten(name)
                end
            end)
            return
        end
        if not net.partnerBosses[name] then
            sendEvent("B", name)
            if isClient() then
                net.hostBosses[name] = true    -- the host fights it too from now on
            end
        end
    end

    ------------------------------------------------------------------ snapshot exchange

    -- The local player, every frame. Only what moves is read this often; see watchSlowly for the rest.
    local slow = { hp = 0, maxhp = 0, cine = 0 }

    local function sendPlayer()
        -- The body of last frame, as long as it's valid and the controller still has it: one call instead of the three
        -- that getPlayer1 makes.
        local pawn = slow.body
        if not (valid(pawn) and slow.pawnAt and link.pointer(slow.pc, slow.pawnAt) == slow.pawn) then
            local pc
            pc, pawn = getPlayer1()
            if pawn == nil then
                return
            end
            slow.body, slow.pawn, slow.pc = pawn, pawn:GetAddress(), pc:GetAddress()
            slow.pawnAt = game.pawnOffset(pc, slow.pc, slow.pawn)
        end
        slow.seenAt = net.frameNow
        local x, y, z, yaw, vx, vy, vz, mode = game.read(pawn, slow.pawn)
        -- Occasionally a read comes back incomplete (seen in PBZ while walking); skip that frame. Same for NaN
        -- (x ~= x), which would send the ghost into nowhere.
        if x == nil or y == nil or z == nil or yaw == nil or x ~= x or y ~= y or z ~= z or yaw ~= yaw then
            return
        end
        if vx ~= vx then
            vx, vy, vz = 0, 0, 0
        end
        local flags = slow.cine * 2
        if mode == MOVE_WALKING then
            flags = flags + 1
        elseif mode == MOVE_FALLING then
            flags = flags + 4
        elseif mode ~= MOVE_NONE then
            flags = flags + 8       -- ladders, wall runs and the like fly the player along their montage
        end
        net.localLoc = { X = x, Y = y, Z = z }
        link.state(x, y, z, yaw, vx or 0, vy or 0, vz or 0, slow.hp, slow.maxhp, net.localMap or 0, flags)
    end

    -- The player's body: the one sendPlayer found valid this frame, or whatever getPlayer1 says.
    local function localPawn()
        if slow.seenAt == net.frameNow then
            return slow.body
        end
        local _, pawn = getPlayer1()
        return pawn
    end

    -- Everything about the local player that doesn't need to go out every frame.
    local function watchSlowly(now)
        local pawn = localPawn()
        if pawn == nil then
            return
        end
        if game.getHealth then
            local hp, maxhp = game.getHealth(pawn)
            slow.hp, slow.maxhp = hp or 0, maxhp or 0
        end
        if net.localMap == nil or now >= (slow.mapAt or 0) then
            slow.mapAt = now + 2.0
            local name = game.mapName and game.mapName(pawn) or "?"
            -- (A failed read isn't a map: as a number it would pass for one, and hide the ghost on the other PC.)
            if name ~= slow.map and name ~= "?" then
                slow.map = name
                net.localMap = link.map(name)
                reach.list, reach.at, reach.near = {}, 1, {}
                net.matchSticky = {}    -- (the old map's addresses are free for new enemies: a late K must not find them)
                net.deadBodies = {}
                if game.forgetActors then
                    game.forgetActors()
                end
                handover.reset()
            end
        end
        local cine = game.inCutscene and game.inCutscene() and 1 or 0
        local okM, mode = pcall(function() return pawn.CharacterMovement.MovementMode end)
        slow.cine = cine
        if cine ~= net.lastCine or mode ~= net.lastMode then
            log("Sending: sequence " .. cine .. ", movement mode " .. tostring(mode) .. ".")
            net.lastCine, net.lastMode = cine, mode
        end
        if net.pvp and game.watchLocalPlayer then
            game.watchLocalPlayer(pawn, sendEvent)    -- ability replays: elsewhere montages say it all (moves.lua)
        end
        if game.watchHitState then
            game.watchHitState(pawn, sendEvent)
        end
        if game.watchItemFx and now >= (slow.itemFxAt or 0) then
            slow.itemFxAt = now + SLOW_S
            game.watchItemFx(pawn, sendEvent)
        end
        -- (The game takes the bars down for a cutscene: put back at once, they'd flicker through it.)
        if next(net.partnerBosses) and game.keepBossBar and now >= (slow.barsAt or 0) and not game.inCutscene() then
            slow.barsAt = now + BOSS_BAR_S
            for name in pairs(net.partnerBosses) do
                local boss = enemyByName[name]
                if valid(boss) and not game.isDead(boss) then
                    game.keepBossBar(boss)
                end
            end
        end
        -- (Never both in a frame: each looks through every actor of a kind.)
        if game.watchPickups and now >= (slow.pickupsAt or 0) then
            if game.watchPickups(pawn, reportPickup) ~= false then
                slow.pickupsAt = now + PICKUP_S
            end
        elseif game.watchChests and (now >= (slow.chestsAt or 0) or net.chestsSoon) then
            slow.chestsAt, net.chestsSoon = now + PICKUP_S, nil
            game.guardFormations()
            game.hookGifts(sendGift)
            game.hookPiles(reportChest)
            game.watchChests(pawn, reportChest, isHost() and offerChest or nil)
            if game.watchStones then
                game.watchStones(pawn, function(name, at, rot)
                    log("Kicked " .. name .. " away: telling the other player where it lies.")
                    sendEvent("KS", name, string.format("%.1f %.1f %.1f %.2f %.2f %.2f", at.X, at.Y, at.Z, rot.Pitch, rot.Yaw, rot.Roll))
                end)
            end
        end
        if (#giftsWaiting > 0 or dustWaiting > 0) and not game.isDead(pawn) then
            takeGifts(pawn)
        end
        if game.watchGear and now >= (slow.gearAt or 0) then
            slow.gearAt = now + GEAR_S
            game.watchGear(pawn, sendGift)
        end
        -- What this player wears, to the others: when it changes, every half minute, and to someone who joins (S).
        if game.ownLook and now >= (slow.lookAt or 0) then
            slow.lookAt = now + 1.0
            local outfit, hidden, skin = game.ownLook(pawn)
            local line = outfit and string.format("%s %d %d", outfit, hidden and 1 or 0, skin)
            if line and (line ~= net.lookSent or now - (net.lookSentAt or -1e9) >= 30) then
                net.lookSent, net.lookSentAt = line, now
                sendEvent("LOOK", line)
            end
        end
        if game.watchCurrency and now >= (slow.dustAt or 0) then
            slow.dustAt = now + CURRENCY_S
            game.watchCurrency(pawn, sendEvent)
        end
        if game.hookRest and not net.restHooked then
            net.restHooked = game.hookRest(function(kind)
                if net.enabled then
                    onLocalRest(kind)
                end
            end)
        end
        if game.hookSit and not net.sitHooked then
            net.sitHooked = game.hookSit(function()
                if net.enabled then
                    onLocalSit()
                end
            end)
        end
    end

    -- Where to show that player this frame.
    local function heard(p, x, y, z, yaw, vx, vy, vz, hp, maxhp, map, flags, silenceMs)
        if x == nil then
            return
        end
        local clock = os.clock()
        local heardAt = clock - silenceMs / 1000
        if p.lastRemoteAt and clock - p.lastRemoteAt >= GAP_LOG_S and silenceMs / 1000 < GAP_LOG_S then
            log(string.format("No packet for %.1f s.", clock - p.lastRemoteAt))
        end
        -- (Heard again after the silence of the load they told of (LOAD): it's over. Its minute went on, and a crash in it was
        -- a frozen figure and a held fight for a minute, not 12 s.)
        if p.loadingUntil and p.lastRemoteAt and heardAt - p.lastRemoteAt >= 3 then
            p.loadingUntil = nil
        end
        if p.byeAt and heardAt > p.byeAt + 1 then
            p.byeAt = nil           -- (their sync is on again: see BYE)
        end
        p.lastRemoteAt = heardAt
        local t = p.target or {}
        t.X, t.Y, t.Z, t.Yaw, t.VX, t.VY, t.VZ = x, y, z, yaw, vx, vy, vz
        t.Hp, t.MaxHp = hp, maxhp
        t.Map = map ~= 0 and map or nil
        t.Grounded, t.Cine, t.Falling, t.Climbing = flags & 1 ~= 0, flags & 2 ~= 0, flags & 4 ~= 0, flags & 8 ~= 0
        p.target = t
        -- (No ghost before we have a player ourselves: menus, loading screens.)
        if not valid(p.ghost) and clock >= (p.ghostTryAt or 0) and valid(select(2, getPlayer1())) then
            p.ghostTryAt = clock + 1.0
            spawnGhost(p)
        end
    end

    local function hearPlayer(slot, x, ...)
        if x ~= nil then
            heard(peerOf(slot), x, ...)
        end
    end

    -- A host's party has no one partner, so net stands for its first guest who's here, for what only asks if someone is. One on
    -- this map if there is one.
    local function followLead()
        local lead, here = nil, nil
        for _, p in ipairs(net.peerList) do
            if p.target and not p.partnerGone then
                lead = lead or p
                if not here and p.target.Map == net.localMap then
                    here = p
                end
            end
        end
        lead = here or lead or net.peerList[1]
        if lead then
            net.lead = lead
            net.target, net.ghost, net.ghostHidden, net.lastRemoteAt = lead.target, lead.ghost, lead.ghostHidden, lead.lastRemoteAt
            net.partnerGone = lead.partnerGone == true
        end
    end

    local function readPartner()
        if net.slot ~= 1 then
            heard(net, link.partner())
        end
        if net.party then
            for slot = 2, net.party do
                if slot ~= net.slot then
                    hearPlayer(slot, link.player(slot))
                end
            end
            if net.slot == 1 then
                followLead()
            end
        end
    end

    ------------------------------------------------------------------ control

    -- Forget everything learned from the other side, so nothing from an earlier session is applied.
    local function clearRemoteState()
        bring.putBackAll()
        handover.reset()
        -- (Which world the host had: a guest turning sync on again with another host, or one that restarted meanwhile,
        -- took the first word of it for that host loading again, and refreshed this player's world in the middle of play,
        -- a fight of their own too. A host restarting while the guest stays linked still does.)
        net.hostWorld = nil
        net.hostLethal, net.deadBodies = {}, {}
        net.everHeard, net.gapped, net.retellAt = nil, nil, nil
        net.bagSent, net.bagDue, net.bagWaiting = false, nil, nil
        net.remoteEnemies = {}
        net.enemyNames = {}
        net.announced = {}
        net.target = nil
        net.localLoc = nil
        net.lastRemoteAt = nil
        net.partnerGone = false
        net.loadingUntil, net.byeAt = nil, nil     -- (a load told last session: its minute, for a crash in this one)
        net.matchSticky = {}
        net.pendingDeaths = {}
        net.pendingBosses = {}
        net.partnerBosses = {}
        net.hostKilled = {}
        net.guestKilled = {}
        net.hostBosses = {}
        net.hitHere = {}
        net.fightOf = {}
        net.notOnHost = {}
        net.bossAsk = {}
        net.joinedBoss, net.joinedWith, net.farFight, net.bossOverAt = nil, nil, nil, nil
        net.healTicks = {}
        net.hostSeen = {}
        net.partnerDowned = false
        enemyByName = {}
        seen = {}
        round.queue, round.at, round.seen, round.held = {}, 1, nil, nil
        reach.near = {}
    end

    local function destroyGhost(p)
        if valid(p.ghost) then
            p.ghost:K2_DestroyActor()
        end
        -- (Its address is free now: left marked as a ghost's, an enemy given it later was never shared nor synced.)
        if p.ghostAddr then
            net.ghostSlots[p.ghostAddr] = nil
            p.ghostAddr = nil
        end
        p.ghost = nil
        p.ghostCmc = nil
        p.ghostHidden = nil
        p.ghostGliding = false
        p.zeroSince = nil
        p.awaySince = nil
    end

    local function destroyGhosts()
        for _, p in ipairs(partners()) do
            destroyGhost(p)
        end
    end

    -- Two players again, or a new start: the other players go, with their ghosts. A guest's host, net, stays.
    local function leaveParty()
        if net.party == nil and next(net.peers) == nil then
            return
        end
        for _, p in pairs(net.peers) do
            destroyGhost(p)
        end
        if net.slot == 1 then
            net.target, net.ghost, net.ghostHidden, net.lastRemoteAt, net.partnerGone = nil, nil, nil, nil, false
        end
        net.peers, net.peerList, net.ghostSlots = {}, nil, {}
        net.party, net.slot, net.number, net.lead, net.watched, net.fights = nil, nil, nil, nil, nil, nil
        net.partnerFighting = false
    end

    local function enterParty(players, slot)
        net.party, net.slot = players, slot
        net.peerList = {}
        if slot ~= 1 then
            net.number, net.lead, net.fights = 1, net, net.partnerFighting
            net.peerList[1] = net
            if net.ghostAddr then
                net.ghostSlots[net.ghostAddr] = 1
            end
        end
        for _, p in pairs(net.peers) do         -- (a tagged event can get here ahead of the hello that says it's a party)
            net.peerList[#net.peerList + 1] = p
        end
        table.sort(net.peerList, function(a, b) return a.number < b.number end)
        log("More than two players (beta): up to " .. players .. ", and you're number " .. slot .. ".")
        if api.pvp and api.pvp.on then
            api.pvp.set(false)
            api.status.notify("pvp", "PvP is off with more than two players.")
        end
    end

    -- What the host's relay says. It can only change as a guest hears a host's hello, or a relay starts.
    local function watchParty()
        local players, slot = nil, nil
        if link.party then
            players, slot = link.party()
        end
        players, slot = players and math.floor(players), slot and math.floor(slot)
        if players ~= net.party or slot ~= net.slot then
            if net.party then
                leaveParty()
            end
            if players then
                enterParty(players, slot)
            end
        end
    end

    local function start(role)
        role = (role ~= nil and role ~= "") and role or "host"
        if role ~= "host" and role ~= "client" then
            log("Usage: neton host|client")
            return
        end
        if link == nil then
            log("Online sync can't start: main.dll can't be reached (see the line above). Reinstall Phantom Pact, check your antivirus didn't remove it, and use the UE4SS build from the install guide.")
            return
        end
        net.role = role
        net.enabled = true
        leaveParty()
        reopenFog()
        clearRemoteState()
        net.deadSent = {}
        slow.map = nil              -- a relay started since (the panel's Join) has yet to hear which map this is
        link.reset()
        if role == "host" then
            sendEvent("Y", hostWorld)
        end
        watchParty()
        log("Online sync on as " .. role .. ".")
    end

    -- A load is silent, the game held up for its length: the partner hears first that this player is loading, and waits
    -- (see watchOnePartner). A trip to another map loads one; a bell's fast travel on the same map only teleports, so
    -- that's told too.
    handlers.LOAD = function(_, from)
        peerOf(from).loadingUntil = os.clock() + 60
    end
    function net.tellLoading()
        if net.enabled then
            pcall(sendEvent, "LOAD")
        end
    end
    pcall(function()
        RegisterHook("/Script/ProjectPBZ.PBZSaveLoadSubsystem:TeleportTo", net.tellLoading)
    end)

    pcall(function()
        RegisterLoadMapPreHook(function()
            net.tellLoading()
            -- Enemies this world brought back for the host go back to dead in it before it's saved and left: put back at the
            -- end of the session, they'd be put back in whatever world is loaded then.
            pcall(bring.putBackAll)
            -- With a player in the world this is a trip: the same world on another map, and a partner's fight goes on. Only a
            -- load from outside it (the title screen) is a world loaded anew.
            if valid(select(2, getPlayer1())) then
                return
            end
            hostWorld = os.time()
            if isHost() then
                sendEvent("Y", hostWorld)
            end
        end)
    end)

    local watchFight

    -- Sync turned off on the other PC: they're gone now, not after 12 s of a figure standing frozen and enemies held for them.
    handlers.BYE = function(_, from)
        local p = peerOf(from)
        p.byeAt = os.clock()
        log("The other player turned sync off.")
        -- (Their relay stays linked, so nothing else on screen says it: their figure only went.)
        if api.status and api.status.notify then
            api.status.notify("conn", (net.party and PLAYERS[p.number or 1].name or "your partner") .. " turned co-op sync off.")
        end
    end

    local function stop()
        pcall(sendEvent, "BYE")
        net.enabled = false
        net.partnerFighting, net.toldFighting = false, nil
        game.holdRespawn(nil, false)
        watchFight(false)
        if net.arriveUntil then
            -- (The hold's end is watched by the tick that's stopping here.)
            net.arriveUntil, net.arrival = nil, nil
            local _, pawn = getPlayer1()
            if valid(pawn) then
                pawn.CharacterMovement:SetMovementMode(MOVE_WALKING, 0)
            end
        end
        if game.spectate then
            game.spectate(nil)
        end
        releaseHeld(nil)
        showAside()
        destroyGhosts()
        if api.mapicon and api.mapicon.hide then
            pcall(api.mapicon.hide)         -- (its ticks end with sync: the partner's marker stayed on the map)
        end
        if api.bullets and api.bullets.endAll then
            pcall(api.bullets.endAll)       -- (and copies of their effects that loop, with nothing left to end them)
        end
        leaveParty()
        endFights()
        reopenFog()
        api.revive.stop()
        game.forgetLink()
        clearRemoteState()
        log("Online sync off.")
    end

    local function status()
        log("Relay: " .. tostring(link and link.status() or "not reachable"))
        local enemyCount = 0
        for _ in pairs(net.remoteEnemies) do
            enemyCount = enemyCount + 1
        end
        local heldCount = 0
        for _ in pairs(net.heldAlive) do
            heldCount = heldCount + 1
        end
        log(string.format("Mod: enabled=%s role=%s ghost=%s events_sent=%d events_in=%d remote_enemies=%d applied=%d hits_reported=%d hits_applied=%d ghost_hits_undone=%d held=%d",
            tostring(net.enabled), net.role, tostring(valid(net.ghost)),
            net.stats.sent, net.stats.received, enemyCount, net.stats.applied, net.stats.hitsReported or 0,
            net.stats.hitsApplied or 0, net.stats.undone, heldCount))
        if valid(net.ghost) then
            local _, pawn = getPlayer1()
            local g = net.ghost:K2_GetActorLocation()
            log("Ghost at " .. fmtVec(g) .. (valid(pawn) and string.format(", %.0f cm from P1", distance(g, pawn:K2_GetActorLocation())) or ""))
        end
        if net.party then
            log(string.format("Party: up to %d, you're number %d.", net.party, net.slot))
            for _, p in ipairs(partners()) do
                log(string.format("  player %d: ghost %s, %s, fighting %s", p.number, tostring(valid(p.ghost)),
                    p.partnerGone and "gone" or p.ghostHidden and "hidden" or "here", tostring(p.fights == true)))
            end
        end
    end

    local ERROR_LOG_S = 2.0       -- a failing stage logs at most this often (it would otherwise spam 20x a second)
    local lastErrorLog = {}       -- stage -> os.clock() of its last logged error

    -- Each stage in its own pcall, so one failing (say, a stale enemy) doesn't stop the others.
    local function runStage(stage, fn)
        local profile = net.profile       -- tools/netlab/perf.lua: time spent per stage
        local began = profile and link.now()
        local ok, err = pcall(fn)
        if began then
            local took = link.now() - began
            local p = profile[stage] or { n = 0, t = 0, max = 0 }
            profile[stage] = p
            p.n, p.t, p.max = p.n + 1, p.t + took, math.max(p.max, took)
        end
        if not ok then
            local now = os.clock()
            if lastErrorLog[stage] == nil or now - lastErrorLog[stage] >= ERROR_LOG_S then
                lastErrorLog[stage] = now
                log("net error (" .. stage .. "): " .. tostring(err))
            end
        end
    end

    -- Nothing from them for a while: they quit, crashed or lost the connection. Their ghost mustn't stand there
    -- frozen, and nothing may stay locked for a fight that's no longer happening (fog walls, held enemies).
    local PARTNER_GONE_S = 12.0   -- longer than a loading screen (respawn teleport, streaming), which is silent too
    local FIGHT_SILENT_S = 3.0    -- enemies leave them alone from here: the ghost waits for a loading screen, the fight doesn't
    local function watchOnePartner(p)
        if isHost() and valid(p.ghost) and not p.ghostHidden then
            local silent = p.lastRemoteAt ~= nil and os.clock() - p.lastRemoteAt >= FIGHT_SILENT_S
            if silent ~= (p.silent == true) then
                p.silent = silent
                game.ghostInFight(p.ghost, not silent, (game.enemiesSoFar()))
            end
        end
        -- (One who said they're loading, LOAD, gets a minute: a trip or a bell's fast travel is silent for 15 s and more on
        -- a slow PC, and as gone they had their fight ended here and, on a guest, every copy woke and fought this player.)
        local wait = os.clock() < (p.loadingUntil or 0) and 60.0 or PARTNER_GONE_S
        local gone = p.lastRemoteAt ~= nil and (os.clock() - p.lastRemoteAt >= wait or p.byeAt ~= nil)
        if gone and not p.partnerGone then
            p.partnerGone = true
            p.fights = nil
            -- What's left behind goes when the host does, or for a host when the last guest does.
            local last = p == net
            if net.slot == 1 then
                last = true
                for _, other in ipairs(partners()) do
                    last = last and other.partnerGone == true
                end
            end
            if last then
                log("Lost the other player (" .. (p.byeAt and "they turned sync off" or "nothing heard for " .. wait .. " s")
                    .. "): fog walls opened, enemies are yours again.")
                bring.putBackAll()
                endFights()
                net.hostBosses, net.pendingBosses = {}, {}
                reopenFog()
                releaseHeld(nil)
                handover.reset()
                net.remoteEnemies = {}
                seen = {}
                net.partnerFighting = false
                watchFight(false)       -- (what ends a watch is that player's own word, and it won't come now)
                restEvent("gone")
                -- What's found alone from here isn't news when they're back: a chest opened meanwhile pays them from its
                -- own copy (OC), and its dust came twice when the count kept running through the gap.
                game.forgetLink()
            else
                log("Lost player " .. p.number .. " (" .. (p.byeAt and "they turned sync off" or "nothing heard for " .. wait .. " s") .. ").")
            end
            if net.party then
                countFights()
                endFights(p.number)     -- (others' bars don't say it's on: those are copies of the same one)
            end
            updateGhostVisibility(p)
        elseif not gone and p.partnerGone then
            p.partnerGone = false
            log("The other player is back.")
            updateGhostVisibility(p)
            -- Back from a gap: what died here meanwhile is told again in a moment, unless they start sync again by then
            -- (S tells them all of it). One never told left that enemy standing in their world.
            if isHost() then
                p.retellAt = os.clock() + 2.0     -- (a player back from a gap: 2 s for their S to come first)
            end
        end
        -- (And the first word from them since this player started sync: one who stayed linked through the host's restart
        -- starts nothing anew, and what the host told as it started, they may have missed.)
        if p.lastRemoteAt and not p.everHeard then
            p.everHeard = true
            if isHost() and not p.retellAt then
                p.retellAt = os.clock() + 2.0
            end
        end
        -- (A shorter gap too, never long enough to count as gone: what was said in it can be lost the same way.)
        local quiet = p.lastRemoteAt and os.clock() - p.lastRemoteAt
        if quiet and quiet > 3.0 then
            p.gapped = true
        elseif p.gapped and quiet and quiet < 1.0 and not p.partnerGone then
            p.gapped = nil
            if isHost() and not p.retellAt then
                p.retellAt = os.clock() + 2.0
            end
        end
        if p.retellAt and os.clock() >= p.retellAt then
            p.retellAt = nil
            if not p.partnerGone and not (p.syncAt and p.syncAt >= os.clock() - 3.0) then
                local slot = net.party and p.number or nil
                for name in pairs(net.deadSent) do
                    if slot then
                        sendTo(slot, "K", name)
                    else
                        sendEvent("K", name)
                    end
                end
                net.tellBosses(slot)
                net.fightToldAt = 0
            end
        end
    end

    local function watchPartner()
        for _, p in ipairs(partners()) do
            watchOnePartner(p)
        end
    end

    -- Spectating: a few seconds into our own death (the death screen's entrance plays first), the camera follows
    -- the other player while they're up and on our map; it comes back to us when we respawn or they go down.
    local SPECTATE_AFTER_S = 3.0
    -- Dead in a boss fight the partner is still in: no respawn until it's over, by the boss dying, the partner dying too or
    -- leaving. (Only there: anywhere else the wait could have no end.)
    local HOLD_LOOK_S = 1.0
    local HOLD_MAX_S = 900.0
    local HOLD_GRACE_S = 5.0      -- the partner's boss bar can come up a few seconds after this player's
    local IN_FIGHT_S = 3.0        -- a fight seen this recently counts: the game takes the bar down as the player dies
    local FIGHT_TOLD_S = 5.0      -- told again this often while it lasts, for a partner who's only just linked
    local FIGHT_GAP_S = 3.0       -- the bar can drop for a moment between a boss's phases

    -- Whether the partner has a boss bar up: only their own game can say a fight is on. A boss nearby says nothing, and
    -- the saves can differ on which bosses are alive at all.
    -- Someone new in a party: a fight that's on is news to them now, not at the next telling.
    handlers.J = function()
        net.fightToldAt = 0
        net.lookSent = nil      -- (and what this player wears: it waited up to 30 s for the next telling)
    end

    handlers.F = function(on, from)
        local p = peerOf(from)
        local was
        if net.party then
            was = p.fights
            p.fights = on == "1"
            countFights()
        else
            was = net.partnerFighting
            net.partnerFighting = on == "1"
        end
        -- Their bar is down for good (F is sent 3 s after it drops, through a phase change): their fight is over, boss
        -- alive or not, as when they died in it, walked out or restarted sync. Its mirror here goes too, for one who walked
        -- in as well: what they fight is a copy of that boss, which does nothing once its own player's fight is over, and
        -- they stood shut in by the walls with it. (The bar came back every second, and the walls stayed shut for nobody.)
        if was and on ~= "1" then
            if from == nil and isClient() then
                net.hostBosses = {}         -- (the host's fights are all over: none comes back at this player's death)
            end
            local whose = net.party and (from or 1) or nil
            for name in pairs(net.partnerBosses) do
                if whose == nil or net.fightOf[name] == whose then
                    log("The other player's fight with " .. name .. " is over there: over here too.")
                    endBossFight(name, enemyByName[name])
                    net.fightOf[name] = nil
                end
            end
        end
    end

    local function tellFight(now)
        if game.bossFightActive() or (net.toldFighting and game.inCutscene()) then
            net.fightHereAt = now
        end
        local fighting = now - (net.fightHereAt or -FIGHT_GAP_S) < FIGHT_GAP_S
        if fighting ~= net.toldFighting or (fighting and now >= (net.fightToldAt or 0)) then
            net.toldFighting, net.fightToldAt = fighting, now + FIGHT_TOLD_S
            sendEvent("F", fighting and 1 or 0)
        end
    end
    extraTicksEarly.tellFight = function()
        local now = os.clock()
        if now >= (net.fightLookAt or 0) then
            net.fightLookAt = now + HOLD_LOOK_S
            tellFight(now)
        end
    end

    -- Who a joiner can watch: on this map, and in a party the one in the fight, who needn't be the host.
    local function fightToWatch()
        for _, p in ipairs(partners()) do
            if (p.fights or not net.party) and valid(p.ghost) and not p.ghostHidden and p.target and p.target.Map == net.localMap then
                return p
            end
        end
        return nil
    end

    -- A guest joining during a boss fight watches it as a player who's down does. From another map there's nothing to
    -- watch: they're told, and go when it's over. The body stays behind with nobody steering, and the ground under it
    -- unloads once the camera's gone: held in the air and kept alive till then, or it fell out of the world.
    watchFight = function(on)
        local _, pawn = getPlayer1()
        if on == (net.watchingFight == true) then
            if on and net.watchHeld and valid(pawn) and pawn.CharacterMovement.MovementMode ~= MOVE_NONE then
                pawn.CharacterMovement:SetMovementMode(MOVE_NONE, 0)
            end
            if on and net.watchHeld and net.party then
                local p = fightToWatch()    -- (the one being watched can go down, with others still in it)
                if p then
                    game.spectate(p.ghost)
                end
            end
            return
        end
        net.watchingFight = on
        if on then
            if api.status then
                api.status.notify("join", "your partner is in a boss fight: you'll join them when it's over.")
            end
            local p = fightToWatch()
            if valid(pawn) and p then
                pawn.CharacterMovement:SetMovementMode(MOVE_NONE, 0)
                game.setMinHealth(pawn, 1)
                game.spectate(p.ghost)
                net.watchHeld = true
            end
        elseif net.watchHeld then
            net.watchHeld = false
            game.spectate(nil)
            game.resetBosses()
            if valid(pawn) then
                game.setMinHealth(pawn, 0)
                if not (net.arriveUntil or net.arrival) then
                    arriveAt(pawn, pawn:K2_GetActorLocation(), 0)     -- not gone anywhere: its own ground has to load again
                end
            end
        end
    end

    -- Who a player who's down can watch: a partner here, one in the boss fight first, and the same one as long as that holds.
    -- The second answer is who's in the fight. With two players that's only ever net, and the fight is net.partnerFighting.
    local function upPartner()
        local first, fighter = nil, nil
        for _, p in ipairs(partners()) do
            if valid(p.ghost) and not p.ghostHidden then
                first = first or p
                if p.fights then
                    fighter = fighter or p
                end
            end
        end
        local stay = net.watched
        if stay and valid(stay.ghost) and not stay.ghostHidden and (stay.fights or fighter == nil) then
            return stay, fighter
        end
        return fighter or first, fighter
    end

    local function holdForFight(pawn, partnerUp, fighting)
        local now = os.clock()
        if not net.holdLooking or now < (net.holdLookAt or 0) then
            return
        end
        net.holdLookAt = now + HOLD_LOOK_S
        local mayWait = partnerUp and not net.pvp and now - net.deadSince < HOLD_MAX_S
        if mayWait and fighting then
            if game.holdRespawn(pawn, true) and not net.holdTold then
                net.holdTold = true
                if api.status then
                    api.status.notify("hold", "you're down: you'll be back when the fight is over.")
                end
            end
        elseif not mayWait or now - net.deadSince >= HOLD_GRACE_S then
            net.holdLooking = false
            game.holdRespawn(pawn, false)
        end
    end

    local function watchOwnDeath()
        local pawn = localPawn()
        if pawn == nil or not game.isDead then
            return
        end
        if game.isDead(pawn) then
            if net.deadSince == nil then
                net.deadSince = os.clock()
                net.holdLooking = net.deadSince - (net.fightSeenAt or -1e9) <= IN_FIGHT_S
                net.holdTold = false
                if game.hideAliveScreen then
                    game.hideAliveScreen()
                end
            end
            if not game.spectate then
                return
            end
            local up, fighter = upPartner()
            local fighting = net.partnerFighting
            if net.party then
                fighting = fighter ~= nil   -- (someone who's down or elsewhere is no reason to wait)
            end
            holdForFight(pawn, up ~= nil, fighting)
            if up and os.clock() - net.deadSince >= SPECTATE_AFTER_S and not game.isSpectating() then
                if game.spectate(up.ghost) then
                    net.watched = net.party and up or nil
                    log("You're down: watching the other player until you respawn.")
                end
            elseif up and net.party and up ~= net.watched and game.isSpectating() then
                net.watched = up            -- the one being watched went down too
                game.spectate(up.ghost)
            elseif not up and game.isSpectating() then
                game.spectate(nil)
                net.watched = nil
                log("The other player is down or gone too: camera back on you.")
            end
        else
            net.deadSince = nil
            if game.bossFightActive() then
                net.fightSeenAt = os.clock()
            end
            if game.isSpectating and game.isSpectating() and not net.watchingFight then
                game.spectate(nil)
                net.watched = nil
                log("Back on your feet: camera back on you.")
            end
        end
    end

    -- Other modules (pvp.lua) run here every tick while sync is on: name -> function.
    local extraTicks = extraTicksEarly

    local sendBudget, nextSlow, nextExtra, lastFrame = 1, 0, 0, nil
    local frameNow, frameDt = 0, 0.016

    local function stageReadEnemies() readEnemies(frameNow) end
    local function stageEnemyTurns() enemyTurns(frameNow, frameDt) end
    local function stageWatchSlowly() watchSlowly(frameNow) end

    -- One frame. What must look smooth runs every time; the rest takes turns, so no single frame pays for it all.
    local function tick()
        if not net.enabled then
            return
        end
        local now = link.now()
        frameNow, frameDt = now, lastFrame and math.min(now - lastFrame, 0.1) or 0.016
        net.frameNow = now
        lastFrame = now
        runStage("processEvents", processEvents)
        runStage("readPartner", readPartner)
        runStage("readEnemies", stageReadEnemies)       -- (a host's: the ones a guest's game runs, see handover)
        -- A budget that fills with time, not a fixed gap after the last send: the tick comes at a slightly different moment
        -- in each frame, and a gap of 1/62 s skipped one frame in four at 60 FPS, so the partner was played further behind.
        sendBudget = math.min(1.5, sendBudget + frameDt * SEND_RATE)
        if sendBudget >= 1 then
            sendBudget = sendBudget - 1
            runStage("sendPlayer", sendPlayer)
        end
        runStage("steerGhost", steerGhosts)
        runStage("enemyTurns", stageEnemyTurns)
        for name, fn in pairs(frameTicks) do
            runStage(name, fn)
        end
        if now >= nextSlow then
            nextSlow = now + SLOW_S
            runStage("watchSlowly", stageWatchSlowly)
            runStage("party", watchParty)
            runStage("visibility", updateVisibility)
            runStage("watchOwnDeath", watchOwnDeath)
            runStage("watchPartner", watchPartner)
        end
        if now >= nextExtra then
            nextExtra = now + EXTRA_S
            for name, fn in pairs(extraTicks) do
                runStage(name, fn)
            end
        end
    end

    -- Everything runs in one loop on the game thread: a delay of 1 ms means once per frame. Never hot-reload the mod
    -- while it runs: UE4SS's Ctrl+R crashed PBZ twice with these loops active.
    LoopInGameThreadWithDelay(1, function()
        tick()
        return false
    end)

    return {
        net = net,
        handlers = handlers,       -- event type -> function(rest); other modules add their own types
        extraTicks = extraTicks,
        frameTicks = frameTicks,
        joinPartner = joinPartner,
        joinFarFight = joinFarFight,
        pressWall = function() net.fogPressAsked = true end,       -- (tests: as a press of E at the wall)
        watchFight = function(on)
            watchFight(on)
        end,
        linked = linked,
        enemyActor = function(name)
            return enemyByName[name]
        end,
        enemies = function()
            return enemyByName
        end,
        restListeners = restListeners,
        isHost = isHost,
        localPawn = localPawn,
        partners = partners,
        peerOf = peerOf,
        players = PLAYERS,
        nearestPartner = nearestPartner,
        watchParty = watchParty,
        -- The body standing for that slot on this PC: this player's own, or a ghost.
        playerBody = function(slot)
            if slot == net.slot then
                return select(2, getPlayer1())
            end
            local p = slot == 1 and net or net.peers[slot]
            return p and p.ghost
        end,
        sendEvent = sendEvent,
        announceBoss = announceBoss,
        reportHit = reportHit,
        reportPickup = reportPickup,
        commands = {
            neton = start,
            netoff = stop,
            netstatus = status,
            -- "ghost clone" (default) or "ghost sphere"; respawns the ghost on the next update.
            ghost = function(mode)
                if mode ~= "clone" and mode ~= "sphere" then
                    log("Usage: ghost clone|sphere (now " .. net.ghostMode .. ")")
                    return
                end
                net.ghostMode = mode
                destroyGhosts()
                log("Ghost look: " .. mode)
            end,
        },
    }
end
