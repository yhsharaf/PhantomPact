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
--       I <pickup> ? - <item> <n>  this pickup was taken, and what it held (a kill's drop: loot:<name> <item> <kind>)
--       O <name>             this chest or rubbish pile was opened: the copy here stops paying
--       T <item> <n> <kind>  the game gave the sender this: the same here
--       W <weapon> <0|1>     what the sender holds, and whether it's drawn (moves.lua)
--       S                    from the relay: the partner has just (re)started sync
--     only worth showing now (dropped if late):
--       U, M, A              a montage or ability of the partner or an enemy (moves.lua, puppets.lua)
--       H <hit state tag>    the sender's player started a hit reaction; their ghost plays the same one
--       HEAL                 guest -> host: the sender started a drink from the gourd; the host's enemies near them look
--                            their way (game.steerTarget). An older host has no handler and leaves it
--     since 1.7.6 (pull request 20, by XxaymanXx). A version before it has no handler for any of these and leaves it:
--       EX <enemy> <1|0> [x y z yaw montage pos]   the sender began, or ended, a finishing move (E) on this enemy:
--                            the other game locks its own E on it and plays the enemy's half of the move
--       PARRY <enemy> <hit state>   a boss was parried or its posture broke in the sender's world: the same state here
--       SHLD <enemy>         an enemy's shield broke in the sender's world: off here too
--       GEOFF <enemy> <effect>   a shield or protection (pbz.lua's MIRROR_EFFECTS, by name) left the enemy there
--       DYN <enemy> <class> <x y z yaw>   host -> guest: a boss's double or summon made as the fight runs, to copy
--       BSHOT <enemy> <bullet data> <x y z pitch yaw roll id>   host -> guest: an enemy's projectile (bullets.lua)
--       PSUM <id> <class> <x y z yaw>, PSUMP <id> <x y z yaw> [montage pos], PSUMEND <id>   a player's summoned ally
--                            (Ctrl powers), shown on the partner's PC: made, where it is now, gone
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
    -- Each enemy in reach gets a turn this often, a few per frame so none costs a hitch: 30 a second (was 10). On the guest a
    -- copy then runs on 3-4 cm past a stop instead of 20 (latency.hpp's run_enemy), and on the bench host, 12 thugs around,
    -- it cost about 2 ms of game thread a second with frame times unchanged (16-17 ms typical, 23-25 at the 99th).
    -- net.enemyRoundS overrides it (a dev eval, for measuring).
    local ENEMY_ROUND_S = 1 / 30
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
        livedAt = {}, livedAs = {},         -- host: actor address -> when, and under which id, it was last seen alive
        metDeadAt = {}, metDeadAs = {},     -- host: actor address -> when, and under which id, it was first met dead
                                            -- with no such sight of it (net.metDead)
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
        lethalPending = {},       -- client: host id -> { at, tries }: a killing blow told, its K not heard yet
        healTicks = {},           -- client: host id -> since when the host's health has been clearly above ours
        hostSeen = {},            -- host, PvP: name -> { hp, posture } last tick, to undo the ghost's own hits
        deadSince = nil,          -- os.clock() when the local player died (spectating starts a little later)
        party = nil,              -- with more than two players: how many at most (the host's PartySize); nil with two
        slot = nil,               -- party: this player's number
        peers = {},               -- party: slot -> what's known of that player (a guest's host is net itself)
        peerList = nil,           -- party: the same, in slot order
        lead = nil,               -- party: who net stands for: a guest's host, or the host's first guest who's here
        ghostSlots = {},          -- party: ghost address -> slot
        hitHere = {},             -- client: enemy id -> this player hit it
        postureTicks = {},        -- client: enemy id -> since when its posture has been above this copy's
        postureFull = {},         -- client: enemy id -> the guard its copy stood at when found at its own most, under the host's
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
    -- (NQ: an enemy's number again, as N, on this lane too. Its lines count only once its name is known, and with the sure
    -- N held up by one lost packet the copy waited about 1.5 round trips without following. HX: a hit's sound and blood,
    -- hitfx.lua: late, it's a sound after the blow.)
    local QUICK = { U = true, M = true, A = true, H = true, Z = true, SHOT = true, BSHOT = true, PSUMP = true, DYN = true, NQ = true, HEAL = true, HX = true }

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
        -- (One batch, one frame: what the handlers look up across a whole map, the spawners, is looked up once for all of
        -- it, and let go at the end. A re-tell after a gap brought 40 deaths at once, each one a search: 100-160 ms in one
        -- frame on the guest.)
        if game.beginBatch then
            game.beginBatch()
        end
        for line in text:gmatch("[^\n]+") do
            -- A move comes with how long ago the partner's game read it, in ms (native/relay.hpp), for its montage to start
            -- that far in: net.eventAgeMs while its handler runs (see moveAge), nil for the rest.
            local age, move = line:match("^~(%d+) (.*)$")
            net.eventAgeMs = tonumber(age)
            line = move or line
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
        net.eventAgeMs = nil
        if game.endBatch then
            game.endBatch()
        end
    end

    -- Seconds since the partner's game was where the event says: the move's own age, or for one with none (the sure lane,
    -- an older DLL) half the round trip, as it was guessed before.
    function net.moveAge()
        return (net.eventAgeMs or (net.rttMs or 0) / 2) / 1000
    end

    local extraTicksEarly = {}  -- name -> function, run EXTRA_S apart (filled below, joined into extraTicks)
    local frameTicks = {}       -- name -> function(dt), run every frame

    ------------------------------------------------------------------ ghost (the remote player)

    -- A clone put away earlier (destroyGhost), of this class, taken back for a new ghost: up, shown and ticking beside player 1.
    -- Nil if none is left in this world.
    function net.unparkClone(cls)
        local list = net.parkedClones
        if not (list and #list > 0 and valid(cls)) then
            return nil
        end
        local cname = cls:GetFName():ToString()
        local all = FindAllOf(cname) or {}
        for i = #list, 1, -1 do
            local k = list[i]
            table.remove(list, i)
            if k.class == cname then
                for _, a in pairs(all) do
                    if valid(a) and a:GetAddress() == k.addr and a:GetFName():ToString() == k.fname then
                        local ok = pcall(function()
                            local _, pawn = getPlayer1()
                            local l = pawn:K2_GetActorLocation()
                            a:SetActorTickEnabled(true)
                            a:SetActorHiddenInGame(false)
                            a:K2_SetActorLocation({ X = l.X + 200, Y = l.Y, Z = l.Z + 50 }, false, {}, true)
                        end)
                        if ok then
                            log("A ghost body put away before taken back.")
                            return a
                        end
                    end
                end
            end
        end
        return nil
    end

    local function spawnGhost(p)
        local ghostClass, cloned = nil, false
        -- (Not a clone in the prologue: a body of the player's own class bound itself to the backpack the game was still
        -- filling, and both players of a new game came out of the tutorial without the healing gourd.)
        if net.ghostMode == "clone" and not (game.inPrologue and game.inPrologue()) then
            local _, pawn = getPlayer1()
            ghostClass = valid(pawn) and pawn:GetClass() or nil
            cloned = valid(ghostClass)
        end
        if not valid(ghostClass) then
            ghostClass = StaticFindObject(GHOST_CLASS)
        end
        p.ghostClone = cloned       -- (for destroyGhost: a clone is put away, never destroyed mid-world)
        p.ghost = net.unparkClone and net.unparkClone(ghostClass) or nil
        if not valid(p.ghost) then
            p.ghost = spawnBesidePlayer1(ghostClass)
        end
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
        p.ghostHidden, p.ghostSolid = nil, nil      -- the last one went with the old world: this one is told afresh
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
        p.ghostBornAt = os.clock()
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
        if dead then
            p.downSeenAt = os.clock()       -- (handlers.K: their dust watch holds back what the game pays them a while after)
            -- (The host still down as a copy's pay, told with them down, waits: none of it comes however late the game
            -- pays it. Read only as the K came, a thug's paying 5.7 s on was taken back, the host down all along.)
            local pay = game.copyPay
            if p == net and pay and pay.hostDownAt and p.downSeenAt - pay.hostDownAt < game.dustWatch.AFTER_DOWN_S then
                pay.hostDownAt = p.downSeenAt
            end
        end
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
        -- Hidden for a scene alone, the partner's or this player's, it keeps its collision. Turned off, the figure left the
        -- trigger of the bell (or chest, or door) it stood by, and the game, which counts one player at a thing, shut that
        -- thing's prompt for this player too: a partner's crane bell scene shut everyone else out of the bell till it
        -- ended (point 3 of a report on 1.7.1; on the bench the prompt went and came back with the figure, 11-12).
        local solid = p.ghostWalks and (not hide or not (dead or gone or otherMap))
        if hide == p.ghostHidden and solid ~= p.ghostSolid then
            p.ghostSolid = solid
            pcall(function()
                p.ghost:SetActorEnableCollision(solid)
                p.ghost.CharacterMovement:SetMovementMode(solid and MOVE_WALKING or MOVE_NONE, 0)
            end)
        end
        if hide ~= p.ghostHidden then
            p.ghostHidden, p.ghostSolid = hide, solid
            p.ghostGliding = false
            pcall(function()
                p.ghost:SetActorHiddenInGame(hide)
                p.ghost:SetActorEnableCollision(solid)
                if p.ghostWalks then
                    -- Without collision it would fall through the world: 20 km by the time it came back.
                    p.ghost.CharacterMovement:SetMovementMode(solid and MOVE_WALKING or MOVE_NONE, 0)
                end
            end)
            if api.moves then
                -- (Its weapon is an actor of its own. Not in the frame the ghost was made, its weapons not set up yet: a
                -- guest crashed in that frame on the bench, a ghost made and hidden at once after a trip. Done a moment later.)
                local ghost = p.ghost
                local wait = 2 - (os.clock() - (p.ghostBornAt or -9))
                if wait > 0 then
                    game.after(wait, function()
                        if valid(ghost) and ghost == p.ghost and p.ghostHidden == hide then
                            pcall(api.moves.hideGear, ghost, hide)
                        end
                    end)
                else
                    pcall(api.moves.hideGear, ghost, hide)
                end
            end
            if isHost() then
                game.ghostInFight(p.ghost, not hide, (game.enemiesSoFar()))
            elseif net.guestOwnFight then
                net.guestOwnFight(p.ghost, hide)
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
            -- (And falling for 0.3 s, not one frame. A step down or a landing a little off from the
            -- partner's spot set it gliding at 15 cm, floating instead of walking and back: the partner "walking
            -- glitchy" on the host's screen, 11-23.)
            local falling = p.ghostCmc.MovementMode == MOVE_FALLING
            if falling then
                p.ghostFallSince = p.ghostFallSince or os.clock()
            else
                p.ghostFallSince = nil
            end
            local noFloor = t.Grounded and t.Z - cur.Z > GHOST_NO_FLOOR_CM and falling
                and os.clock() - p.ghostFallSince >= 0.3
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
        local gnow = os.clock()
        local gdt = math.min(0.05, math.max(0.001, gnow - (p.steerAt or (gnow - 0.016))))
        p.steerAt = gnow
        local a = (t.Climbing or distance(cur, t) > GHOST_SNAP_CM) and 1.0 or (1 - math.exp(-16.0 * gdt))
        local okR, rot = pcall(function() return p.ghost:K2_GetActorRotation() end)
        local curYaw = (okR and rot and rot.Yaw) or t.Yaw or 0
        local yaw = curYaw + (((t.Yaw or curYaw) - curYaw + 180) % 360 - 180) * a
        p.ghost:K2_SetActorLocationAndRotation(
            { X = cur.X + (t.X - cur.X) * a, Y = cur.Y + (t.Y - cur.Y) * a, Z = cur.Z + (t.Z - cur.Z) * a },
            { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false, {}, true)
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
        local gnow = os.clock()
        local gdt = math.min(0.05, math.max(0.001, gnow - (p.steerAt or (gnow - 0.016))))
        p.steerAt = gnow
        local yawA = 1 - math.exp(-18.0 * gdt)
        local okR, rot = pcall(function() return p.ghost:K2_GetActorRotation() end)
        local curYaw = (okR and rot and rot.Yaw) or t.Yaw or 0
        local smYaw = curYaw + (((t.Yaw or curYaw) - curYaw + 180) % 360 - 180) * yawA
        local dx, dy = t.X - cur.X, t.Y - cur.Y
        local dist = math.sqrt(dx * dx + dy * dy)
        if game.ghostBusy and game.ghostBusy(p.ghost) and dist < GHOST_CORRECT_CM then
            -- Mid attack/dodge the move's own motion plays out, with a smooth dt-scaled pull.
            if dist > GHOST_BUSY_CM then
                local bp = 1 - math.exp(-6.0 * gdt)
                p.ghost:K2_SetActorLocation({ X = cur.X + dx * bp, Y = cur.Y + dy * bp, Z = cur.Z },
                    false, {}, false)
            end
            p.ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = smYaw, Roll = 0.0 }, false)
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
            p.ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = smYaw, Roll = 0.0 }, false)
            return
        end
        local a = 1 - math.exp(-16.0 * gdt)
        p.ghost:K2_SetActorLocationAndRotation(
            { X = cur.X + (t.X - cur.X) * a, Y = cur.Y + (t.Y - cur.Y) * a, Z = cur.Z + (t.Z - cur.Z) * a },
            { Pitch = 0.0, Yaw = smYaw, Roll = 0.0 }, false, {}, true)
    end

    local function steerGhosts()
        for _, p in ipairs(partners()) do
            steerGhost(p)
        end
    end

    handlers.M = function(rest, from)
        local path, yaw = rest:match("^(%S+)%s*(%S*)")
        -- (On the sender's own ghost: in a party, net.ghost is the lead's, and every player's move played on it.)
        local p = net.party and peerOf(from) or net
        local ghost = p.ghost
        -- (pvp.lua: an attack of theirs opens a swing to judge a parry by, aimed where they faced as it began.)
        local y = tonumber(yaw)
        p.moveAt, p.movePath, p.moveYaw = os.clock(), path, (y and y == y and math.abs(y) <= 720) and y or nil
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
            -- (Asked first whether it's still there: the list is up to half a second old, and its enemies can be gone by
            -- now, a rest's or a death's refresh, a camp put away. Read by its address all the same, the fast read went
            -- through whatever that memory holds now.)
            if addr ~= net.ghostAddr and not net.ghostSlots[addr] and valid(e) then    -- (an address a ghost took over from an enemy, until facts are cleared)
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
        local now = os.clock()
        if not net.classCache or now - (net.classCacheAt or 0) >= 30.0 then
            net.classCache, net.classCacheAt = {}, now
        end
        local addr = actor:GetAddress()
        local c = net.classCache[addr]
        if c == nil then
            c = actor:GetClass():GetFName():ToString()
            net.classCache[addr] = c
        end
        return c
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
            local class = enemyClass(actor)
            sendEvent("N", n, name, class)
            sendEvent("NQ", n, name, class)
        end
        return n
    end

    -- The other player's boss fight, mirrored on our copy of that boss: boss bar and closed fog walls.
    local function mirrorBossFight(name, actor)
        if game.showBossBar then
            game.showBossBar(actor)
            -- (The copy the bar went on, by address and name: its pairing can be lost before the fight ends, and the bar
            -- stayed up on it for good.)
            net.mirrorOn = net.mirrorOn or {}
            net.mirrorOn[name] = { actor = actor, addr = actor:GetAddress(),
                fname = select(2, pcall(function() return actor:GetFName():ToString() end)) }
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
        net.struck[name] = nil
        if net.joinedBoss == name then
            net.joinedBoss = nil
            if net.joinedFar then
                net.bossOverAt, net.bossOverFirst = os.clock() + BOSS_RETURN_S, nil     -- (an arena apart from the map has no way back)
            end
        end
        local shown = net.mirrorOn and net.mirrorOn[name]
        if net.mirrorOn then
            net.mirrorOn[name] = nil
        end
        if shown and valid(shown.actor) and shown.actor:GetAddress() == shown.addr
            and select(2, pcall(function() return shown.actor:GetFName():ToString() end)) == shown.fname
            and not (valid(actor) and actor:GetAddress() == shown.addr) and game.hideBossBar then
            game.hideBossBar(shown.actor)       -- (the copy it went on, no longer the one the id points to)
        end
        if valid(actor) then
            at = at or actor:K2_GetActorLocation()
            if game.hideBossBar then
                game.hideBossBar(actor)
            end
        end
        -- (A figure put on the enemy's side for this fight, still alive and not started here: back as it stood. pbz.lua's
        -- game.enemySide.)
        if game.ownSide then
            local back = valid(actor) and game.ownSide(actor)
            if shown and valid(shown.actor) and shown.actor:GetAddress() == shown.addr
                and not (valid(actor) and actor:GetAddress() == shown.addr) then
                back = game.ownSide(shown.actor) or back
            end
            if back then
                log(name .. " is as the game had it again: not started in this world, its own start still to come.")
            end
        end
        if at and game.setBossFog then
            game.setBossFog(at, false)
        end
        -- (The stand-in this PC spawned for that fight, if it's still standing: the fight over without its death. See
        -- game.dropStandIn. One that died, the host's kill, is dead already and stays.)
        local stand = net.spawnedFor and net.spawnedFor[name]
        if stand then
            net.spawnedFor[name] = nil
            if game.dropStandIn and game.dropStandIn(stand) then
                log("The boss spawned here for the other player's fight with " .. name .. " went with that fight.")
            end
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

    -- Host: a kill's items for the client, one pickup event each. paid collects what to say in the log. to: in a party,
    -- the one guest whose kill it was (sent to all, every guest was paid for every other guest's kills).
    local function sendItems(name, items, paid, to)
        for _, item in ipairs(items) do
            for _ = 1, item.count do
                if to and net.party then
                    sendTo(to, "I", "loot:" .. name, item.id, item.kind or "-")
                else
                    sendEvent("I", "loot:" .. name, item.id, item.kind or "-")
                end
            end
            paid[#paid + 1] = item.id .. " x" .. item.count
        end
    end

    -- Host: the client's hit killed this enemy. The game's own loot roll didn't run (see game.rollLoot), so it's
    -- rolled here, once. Dust goes to the host like any kill's and reaches the client as shared dust ("C"); items go to
    -- both, unless the client's game already paid its player (theirsPaid: the death ran there first).
    local function payKillLoot(name, actor, theirsPaid, to)
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
            sendItems(name, items, paid, to)
        end
        if #paid > 0 then
            log(string.format("Your partner's kill (%s, level %d): %s.", name, level, table.concat(paid, ", ")))
        end
        return dust, items
    end

    -- On the PC running the enemy, every ghost here goes on its hatred list, and who it goes for is steered among the
    -- players near it (game.steerTarget). Their ghosts' places are what the relay last said: no calls into the game for each
    -- of them. With two players the partner is net, in slot 2. In PvP the partner is the one to fight: hated, never steered.
    local function aggroParty(actor, addr, x, y, z, hp, name)
        local here = {}
        local localSlot = net.slot or (isClient() and 2 or 1)
        for _, p in ipairs(partners()) do
            -- (Same map only: in the 3 s before a ghost hides, a partner's spot on another map turned enemies to nothing.)
            if valid(p.ghost) and not p.ghostHidden and not p.silent and p.target and sameMap(p.target) then
                game.hateGhost(actor, p.ghost, addr, x, y, z, p.number, p.target)
                here[#here + 1] = { body = p.ghost, addr = p.ghostAddr, at = p.target,
                    slot = p.number or (localSlot == 1 and 2 or 1) }
            end
        end
        local _, pawn = getPlayer1()
        if valid(pawn) and not game.isDead(pawn) and net.localLoc then
            here[#here + 1] = { body = pawn, addr = pawn:GetAddress(), at = net.localLoc, slot = localSlot, mine = true }
        end
        -- (Also with one player near, or none: an enemy steered till now gets its own picker back.)
        if #here > 0 and not net.pvp and game.steerTarget then
            game.steerTarget(actor, addr, x, y, z, hp, here, game.isBoss and game.isBoss(actor, addr),
                api.puppets and api.puppets.inMove(name))
        end
    end

    -- The host's game wakes enemies for its own player alone: its optimizer and its fight areas, which only ever take the host
    -- in, kept the ones by a guest some way off asleep, and their copies on the guest's side stood there with them, never
    -- swinging. So with two players apart, an enemy clearly nearer the guest is run by the guest's game, where the guest is the
    -- player and it wakes as the game always does, and the host's copy follows the guest's lines and moves as a guest's copies
    -- follow the host's. It's the host's again once the two are together, once it's clearly nearer the host, or when the
    -- guest's game goes quiet about it. One fighting the host, and anything without a spawner's id (which the two PCs
    -- might name apart) stay the host's. Two players only: a party's relay carries enemy lines from the host alone.
    -- A boss goes by its fight (handover.bossGoes): the guest's game runs one the guest is fighting and the host isn't.
    -- With three or more, one asleep here is each guest's own to run a copy of meanwhile (handover.asleepHere).
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
        asleep = {},            -- a party's host: id -> true while it sleeps here with a guest by it (asleepHere)
        mountAt = {},           -- guest: id of one this game runs -> os.clock() when what it rides is next asked
        mineMounts = {},        -- guest: address of what such a one rides -> os.clock() when it was last seen to (410)
    }

    -- An enemy's line goes the moment it says something new, and one that says the same as the last only every ENEMY_SAME_S,
    -- so the other side never takes it for gone. Most enemies stand most of the time: in recordings of real fights, 88-99%
    -- of their samples said what the one before did, and each went out 30 times a second all the same. (Fields of net, not
    -- locals: this function is at Lua's 200 locals.)
    -- A line goes once and isn't sent again if it's lost. One that said something new is made good by the next that does,
    -- a turn on; but the last of them (the enemy stopped, or was hit as it stood) had only the line every ENEMY_SAME_S
    -- after it, and at 2% loss, one time in a hundred, a copy ran on 70 cm past its stop and its health showed a third of a
    -- second late (netsim). So a line that says the same as the last goes again the turn after it first went, and once more
    -- two turns after that (net.enemyAgain turns), before it's left to ENEMY_SAME_S.
    net.linesSent = {}            -- enemy number -> { text, at, again }
    net.enemySameS = 0.25         -- a line that says nothing new goes again this often (ENEMY_STALE_S allows for two)
    net.enemyAgain = { 0.9, 1.9 } -- and before that, this many turns after it went: the first time, then the second
    function net.sendEnemyLine(number, text)
        local last = net.linesSent[number]
        local now = net.frameNow
        if last and last.text == text then
            local turns = net.enemyAgain[last.again + 1]
            if now - last.at < (turns and turns * (net.enemyRoundS or ENEMY_ROUND_S) or net.enemySameS) then
                return
            end
            if turns then
                last.again = last.again + 1
            end
        elseif last then
            last.text, last.again = text, 0
        else
            last = { text = text, again = 0 }
            net.linesSent[number] = last
        end
        last.at = now
        link.enemy(text)
    end

    -- Whether an enemy read as dead is one only met so: not seen alive here, at this address and under this id, a
    -- moment ago. True while it has yet to lie MET_DEAD_S: then it's a body, and told as ever. (By address and id
    -- both: a new actor at an address another had isn't the one seen alive there. And a rest or a death of this
    -- player's, which makes every enemy anew, forgets who was seen: onLocalRest.)
    net.MET_DEAD_S, net.LIVED_S = 3.0, 5.0
    function net.metDead(name, addr)
        local now = net.frameNow or link.now()
        if net.livedAs[addr] == name and now - (net.livedAt[addr] or -1e9) < net.LIVED_S then
            return false
        end
        if net.metDeadAt[addr] == nil or net.metDeadAs[addr] ~= name then
            net.metDeadAt[addr], net.metDeadAs[addr] = now, name
            return true
        end
        return now - net.metDeadAt[addr] < net.MET_DEAD_S
    end

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
        if api.hitfx and hp then
            -- (This player's own hits' sound and blood, for everyone else: hitfx.lua. One a guest's game runs only noted.)
            api.hitfx.runs(name, actor, addr, hp, net.guestRuns[name])
        end
        -- At 0 health it's dead, and that's all most turns need; asking the game costs more and rarely says otherwise.
        local dead = hp ~= nil and hp <= 0
        -- (One already announced is asked every turn: dead by the game's word at full health, it mustn't flip back.)
        if not dead and game.isDead and (round.number % 3 == 0 or net.deadSent[name]) then
            dead = game.isDead(actor)
        end
        -- (A death is of one seen alive. An actor whose numbers aren't set yet reads no health: a boss its opening
        -- scene has only just made. Met so, it was told as dead that turn: "Enemy died here", by its actor's own
        -- name, a tenth of a second before "a scene begins" at each such boss of the user's play logs of 11-19. By
        -- that name it means nothing to a guest; but it counted as a boss's fall, and a scene within FELL_S of one
        -- isn't told (story.lua's fellLately): the opening scene, of all scenes, wasn't shared with a partner
        -- standing by, and the phase after it was called a fight a whole scene early. One met dead that this world
        -- hasn't seen alive a moment ago is a body only once it has lain MET_DEAD_S, and nothing is said of it till
        -- then. (The enemies a rest or a death makes anew aren't such: each comes with its health on its first
        -- frame, the bench's run247.) 408.)
        if dead and not net.deadSent[name] and net.metDead(name, addr) then
            return
        end
        local paidThere = false
        -- (Not one the guest's game ran: the floor on its copy here is the handover's own, and its death ran its whole
        -- script there. One asleep here in a party is held by nothing: a floor on it is the game's own, and it's fought
        -- here like any other on one. The review of 11-16.)
        if not dead and net.guestKilled[name] and not net.guestRuns[name]
            and game.healthFloor and game.healthFloor(actor) >= 1 and game.isBoss and game.isBoss(actor, addr) then
            -- A boss held up by its own floor (its phase ends in a scene) isn't the guest's kill to make: killed from here it
            -- died outside its script, with no scene after, its body left, and the story stuck in the host's save. It's
            -- fought here.
            net.guestKilled[name] = nil
            log("The other player's kill of " .. name .. " isn't taken: its fight goes on here, in the game's own way.")
        end
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
            -- (Not left standing frozen till it goes: the game's own death, at level 0, as a guest's copies die: what
            -- listens for deaths here (a quest's encounter) hears of it.)
            -- (A boss too: the quiet kill skipped its scene after and its story, and left its body. One the game won't let die
            -- now is left to its fight here: killForReal doesn't force a boss.)
            local boss = game.isBoss and game.isBoss(actor, addr)
            local real = false
            if game.killForReal then
                real = game.killForReal(actor)
            else
                game.kill(actor)
            end
            dead = real or not boss or not game.killForReal
            paidThere = true        -- the guest's game ran that death itself, loot and all
        end
        if dead then
            -- (A guest's kill heard after it died here anyway is done with: kept, it killed the spawner's next enemy under
            -- that id on its first turn.)
            net.guestKilled[name] = nil
            handover.asleep[name] = nil
            game.unfocus(addr, actor)   -- (who hit it is forgotten: a later enemy may get its address)
            if net.guestRuns[name] then
                handover.drop(actor, addr, name)
            end
            -- (And by the body: a rest forgets the names, and a spawner's new enemy under the same id clears its name each
            -- turn, so the old body's turn told its death again, every round: boss items paid twice, and the guest's live
            -- copy killed.)
            -- (The body by its address and actor name: by address alone, a later enemy that got a collected body's
            -- address was taken for it, and its death never told. Not by id: a body's id can change once it's dead (its
            -- spawner no longer linked), and told again under the new one, a boss's items went out twice.)
            local body = tostring(select(2, pcall(function() return actor:GetFName():ToString() end)))
            if not net.deadSent[name] and net.deadBodies[addr] ~= body then
                net.deadSent[name] = true
                net.deadBodies[addr] = body
                sendEvent("K", name)
                log("Enemy died here: " .. name .. "; telling the other player.")
                if game.markBeaten then
                    game.markBeaten(name)
                end
                local boss = net.partnerBosses[name] or net.pendingBosses[name] or (game.isBoss and game.isBoss(actor))
                if boss and not isClient() and (net.toldFighting or game.bossFightActive()) then
                    net.fellInFight = net.fellInFight or {}
                    net.fellInFight[name] = os.clock()      -- (fell in a fight here: see "up again" below)
                end
                if boss and not isClient() then
                    net.bossFellAt = os.clock()             -- (its win's flow goes out whole: flowsync.lua's hostTick)
                end
                -- (Once for each body: a restart or a map change forgets which bodies were told, and a boss's body still
                -- lying there was told again, its items paid again.)
                net.bossPaid = net.bossPaid or {}
                -- (A boss of the fight this player went down in, dead with them down: its pay is owed till they're up, and
                -- its win's steps come from a guest's world. pbz.lua's payOwed, flowsync.lua's DB.)
                local owed = net.deadSince ~= nil and game.downBoss and game.downBoss(name, boss)
                if (boss or owed) and not paidThere and game.rollLoot and net.bossPaid[addr] ~= body then
                    net.bossPaid[addr] = body
                    -- The game paid the host. A boss's items are the client's too: by the share of what the game gave
                    -- (T). Told by name as well only when owed, this player down (see handlers.D).
                    local bossDust, items = game.rollLoot(actor)
                    local paid = {}
                    if owed then
                        sendItems(name, items, paid)
                    end
                    if #paid > 0 then
                        log("Boss items for your partner too: " .. table.concat(paid, ", ") .. ".")
                    end
                    if owed then
                        game.oweBoss(name, bossDust, items)
                    end
                end
                -- (A copy of another's fight only: this game's own fight is its own to end, its bar and walls the game's. At
                -- Xiaoxue's fall, which she gets up from, the host's bar was taken down and its walls opened mid-fight.)
                if net.partnerBosses[name] or net.pendingBosses[name] or (game.isMirrorBar and game.isMirrorBar(actor)) then
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
            -- A boss that fell in its fight up again here (Xiaoxue): still a fight, though no new bar came. The mod had let go
            -- of it at its death, and the others' copies came back with no bar, walls or fight, their death a quiet one.
            if net.deadSent[name] and net.fellInFight and net.fellInFight[name] then
                local fell = net.fellInFight[name]
                net.fellInFight[name] = nil
                -- (Its record written beaten at the fall: alive again, or this world's B answered every guest "beaten" and
                -- their copy was killed on sight: "the boss vanishes for the guest and only the host gets the reward".)
                if game.unmarkBeaten then
                    game.unmarkBeaten(name)
                end
                if os.clock() - fell < 600 and game.trackBoss and game.trackBoss(actor) then
                    log("Boss " .. name .. " is up again here after its fall: still a fight.")
                    net.ownFightOn(actor)
                end
            end
            -- Alive (again, after a bell respawn): its next death must be announced too.
            net.deadSent[name] = nil
            net.deadBodies[addr] = nil
            -- (And it's one seen alive, here and now: net.metDead.)
            net.livedAt[addr], net.livedAs[addr], net.metDeadAt[addr] = net.frameNow or link.now(), name, nil
            if net.bossPaid then
                net.bossPaid[addr] = nil
            end
            -- (And nothing is owed for it: a fall it gets up from, Xiaoxue's, with this player down, isn't a win. The review.)
            if game.owedNames and game.owedNames[name] and game.dropOwed then
                game.dropOwed(name)
                if api.flowsync and api.flowsync.dropOwed then
                    api.flowsync.dropOwed(name)
                end
                log("Boss " .. name .. " is up again: nothing owed for its fall.")
            end
            if handover.guestRuns(name, actor, addr, x, y, z) and handover.follow(name, actor, addr, hp, posture) then
                return              -- (the guest's game runs it: what it does comes from there)
            end
            if api.puppets then
                api.puppets.watchHost(name, actor, addr)
            end
            if game.refillEmptied then
                posture = game.refillEmptied(actor, addr, posture)     -- (a bar a partner emptied, never filled again)
            end
            if yaw == yaw and x == x and y == y and z == z then
                local boss = game.isBoss and game.isBoss(actor, addr) and 1 or 0
                if (boss == 1 or (game.bossTwin and game.bossTwin(actor, addr))) and game.watchBossBar then
                    game.watchBossBar(actor, addr, posture)     -- (its breaks and fills, for a partner's blows: handlers.D)
                end
                -- (Asleep here with a guest by it, in a party: each guest's game runs its own copy. handover.asleepHere.)
                if handover.asleepHere(name, actor, addr, x, y, z, boss == 1) then
                    boss = boss + 2
                end
                -- "-" = unknown posture; the client leaves its own alone instead of zeroing it.
                local number = enemyNumber(actor, name)
                -- (One kept at its game's most stands for f times it, scaling.lua's capped: its line says co-op's numbers,
                -- as it did before its game cut it. Looked at here first, any body scaled here: a line with the cut in
                -- it, or with a blow not yet given back, pulled every copy down by it, and a copy isn't lifted again
                -- under 5%; and one with no bar, first known at the scaling's pass, was kept whole there, a guest's
                -- blows before the cut undone.)
                local f = 1
                if api.scaling and api.scaling.watched and (boss % 2 == 1 or api.scaling.watched(addr)) then
                    if api.scaling.look then
                        api.scaling.look(actor, addr, hp, maxhp)
                    end
                    f = api.scaling.capped(actor, addr) or 1
                    if f ~= 1 then
                        local has, most = game.getHealth(actor)
                        if has and most then
                            hp, maxhp = has, most
                        end
                    end
                end
                if name:sub(1, 3) ~= "sp:" and not name:match("^tw%d+:") and game.classPathOf then
                    net.dynSent = net.dynSent or {}
                    local dnow = os.clock()
                    if dnow - (net.dynSent[name] or 0) >= 4.0 then
                        local cpath = game.classPathOf(actor)
                        local cls = cpath and cpath:match("%.([^%.]+)$") or ""
                        -- Whitelist DYN strictly to true dynamic boss splits/summons (StuntDouble & For<Boss>*),
                        -- NEVER real bosses or _Stand_C stand-ins (prevents duplicate bosses & fake heal spam!)
                        if cpath and cpath:find("^/") and net.dynClassOK and net.dynClassOK(cls) then
                            net.dynSent[name] = dnow
                            sendEvent("DYN", name, cpath, string.format("%.0f %.0f %.0f %.0f", x, y, z, yaw))
                        end
                    end
                end
                net.sendEnemyLine(number, string.format("%d %.0f %.0f %.0f %.0f %.0f %.0f %.1f %.1f %d %s", number,
                    x, y, z, yaw, vx == vx and vx or 0, vy == vy and vy or 0, hp * f, maxhp * f, boss,
                    posture ~= nil and string.format("%.1f", posture) or "-"))
            end
            if aggro and game.hateGhost then
                aggroParty(actor, addr, x, y, z, hp, name)
            end
        end
    end

    -- id is the HOST's id for this enemy (it may differ from our own when matched by class and position).
    -- lethal: our copy is held at 1 health (only the host kills it), so a killing blow can't show its full damage
    -- here; it's sent as lethal and the host kills the enemy.
    -- A host reports its hits on one the guest's game runs (handover), the other way round.
    -- With the reaction the hit made here (puppets.reactionOf: montage, position, hit state), for the enemy itself to show.
    local function reportHit(id, enemy, hpDamage, postureDamage, lethal, finisher)
        if net.enabled and (isClient() or net.guestRuns[id]) and valid(enemy) then
            local path, pos, tag
            if api.puppets and not lethal then
                path, pos, tag = api.puppets.reactionOf(enemy)
            end
            sendEvent("D", id, string.format("%.1f", hpDamage), string.format("%.1f", postureDamage or 0),
                lethal and (finisher and "X" or "L") or "-", path or "-", string.format("%.2f", pos or 0), tag or "-")
            net.stats.hitsReported = (net.stats.hitsReported or 0) + 1
            if api.hitfx and hpDamage > 0.5 then
                api.hitfx.ownHit(id, enemy)
            end
            if isClient() and hpDamage > 0 then
                net.hitHere[id] = true      -- (see GK in syncEnemy)
            end
            -- (A guest in that boss's fight: see net.fightingHere. Any hit, a parry's posture too. A host's on a boss of
            -- the guest's fight, which the guest's game runs, the same: from near it, the boss is this game's from then on,
            -- handover.hostIn. And on a party's guest, any one asleep on the host: one the game gives a boss's bar and
            -- the codex doesn't call a boss (the hook man) is a boss only while its bar is up, and a held copy's bar is
            -- taken down at once, handover.byHere: its blows from 40 m set no mark, and wore down a copy that never
            -- fought back. The sixth review.)
            if net.partnerBosses[id] or (isClient() and game.isBoss and game.isBoss(enemy))
                or (net.party and isClient() and (net.remoteEnemies[id] or {}).Asleep == true) then
                net.struck[id] = true
                net.struckAt[id] = os.clock()   -- (the blow itself, for handover.byHere)
            end
        end
    end

    -- A name that is one PC's alone: an actor's own (an enemy no spawner with an id made), or an older build's name
    -- for a spawner the game made as it ran (game.runtimeName, 410). Never a ghost twin's.
    net.MOUNTS_S = 0.5            -- client: what one this game runs rides is asked at most this often (handover.rides)
    net.MOUNT_NEAR_CM = 500       -- client: the host's line of a mount is within this of its line of the rider
    net.NO_RIDERS = {}
    net.MINE_MOUNT_S = 1.5        -- client: what a rider this game runs rode this lately is still its mount
    function net.ownName(id)
        if id:match("^tw%d+:") then
            return false
        end
        return id:sub(1, 3) ~= "sp:" or (game.runtimeName ~= nil and game.runtimeName(id))
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
        -- (What a rider this game runs rides is this game's own too, no copy of any line of the host's: a boss the
        -- guest fights and the host doesn't is the guest's game's to run, 263, and in a party one asleep on the host
        -- is each guest's by it, 277; its horse, paired with the host's own, asleep there, was held and steered to
        -- where that one stood, the rider on it. handover.rides notes what each such rider rides. 410.)
        local roundClock = os.clock()
        local function ridden(e)
            local at = handover.mineMounts[e.addr]
            return at ~= nil and roundClock - at < net.MINE_MOUNT_S
        end
        -- (The host's boss only ever paired with one of its own kind here: a late joiner's world with no copy of it had
        -- another enemy paired by the id, which played the boss's moves under its bar (player report 11-09: Tie Gui as a mob
        -- with Jing Ye's name), and hits on it reached nothing. By class, not by the codex's boss mark: some story bosses
        -- are of an ordinary enemy's class.)
        local function fits(id, e)
            local r = net.remoteEnemies[id]
            if not (r and r.Class) then
                return true
            end
            e.class = e.class or enemyClass(e.actor)
            if r.Boss then
                return e.class == r.Class
            end
            local rStand = r.Class:find("_Stand_C$") ~= nil
            local eStand = type(e.class) == "string" and e.class:find("_Stand_C$") ~= nil
            return rStand == eStand
        end
        for _, id in ipairs(ids) do
            local e = byId[id]
            -- (Not a body: matched to a host enemy that's alive, its death here was sent on as the guest's kill, GK, and
            -- killed the host's, a fresh one after a rest too.)
            if e and not used[e.addr] and not isDead(e.actor) and fits(id, e) then
                take(id, e)
            end
        end
        for _, id in ipairs(ids) do
            local e = byAddr[net.matchSticky[id]]
            if matched[id] == nil and e and not used[e.addr] and not (game.isDead and game.isDead(e.actor)) and not ridden(e) then
                -- (Still the same kind: another enemy can be at a gone one's address, and was steered as the host's.)
                local want = net.remoteEnemies[id] and net.remoteEnemies[id].Class
                e.class = e.class or (want and enemyClass(e.actor))
                if (not want or e.class == want) and fits(id, e) then
                    take(id, e)
                end
            end
        end
        -- A mount is its rider's. What a copy of the host's rides here (puppets.ridden: each copy is asked twice a
        -- second) is the host's enemy of that kind, with no id of both PCs, that stands where the host's line has the
        -- rider: a rider is attached to its mount, so their two lines say one place. However far off this world's
        -- own stands, and whatever it or that line was paired with before. (Jing Ye's horse is an enemy of its own,
        -- from a spawner the game makes as it runs, with no name the two PCs share. By kind and nearness it was
        -- paired only within ENEMY_MATCH_CM of the host's; further off, its own game's horse run after this player
        -- while the host fought, it never was: it ran by itself, or was put out of the way as one the host hasn't
        -- got, and its rider's copy, dragged to the host's line, rode nothing. Players on 1.7.4, 11-20: 410. And by
        -- kind and nearness two riders' horses can be paired crosswise: each rider's copy is left on its mount now,
        -- puppets.lua, and would stand where the other's is. 412.)
        for mountAddr, riderId in pairs(api.puppets and api.puppets.ridden or net.NO_RIDERS) do
            local e, rider = byAddr[mountAddr], net.remoteEnemies[riderId]
            if e and rider and rider.X and matched[riderId] ~= nil and not isDead(e.actor) and not ridden(e) then
                e.class = e.class or enemyClass(e.actor)
                local best, bestD = nil, net.MOUNT_NEAR_CM
                for _, id in ipairs(ids) do
                    local r = net.remoteEnemies[id]
                    if r.Class == e.class and not r.Boss and r.X and net.ownName(id) then
                        local d = math.sqrt((r.X - rider.X) ^ 2 + (r.Y - rider.Y) ^ 2)
                        if d < bestD then
                            best, bestD = id, d
                        end
                    end
                end
                if best and matched[best] ~= e.actor then
                    local had = matched[best]
                    if had ~= nil then
                        used[had:GetAddress()] = nil        -- (what held that line: free for another again)
                    end
                    for id, actor in pairs(matched) do
                        if actor == e.actor then
                            matched[id] = nil               -- (and the line this mount was paired with before)
                        end
                    end
                    take(best, e)
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
                    if not used[e.addr] and not isDead(e.actor) and not ridden(e) then
                        e.class = e.class or enemyClass(e.actor)    -- three calls through UE4SS, for each pair, each round
                        if e.class == r.Class then
                            local d = distance(e.loc, r)
                            if d < bestD then
                                best, bestD = e, d
                            end
                        end
                    end
                end
                if best and fits(id, best) then
                    take(id, best)
                end
            end
        end
        -- Remember the pairings. One whose id skipped this snapshot stays while its actor is still loaded.
        -- (Not for good: a pairing outlived its lines with no end, a body's too, and the actor, never this world's own again,
        -- was never asked about nor put aside. 10 s with no line, a death on the host, or a body, and it's let go.)
        local sticky = {}
        net.stickySeen = net.stickySeen or {}
        local clock = os.clock()
        for id, addr in pairs(net.matchSticky) do
            local e = byAddr[addr]
            if e and net.remoteEnemies[id] == nil and not net.hostKilled[id] and not isDead(e.actor)
                and clock - (net.stickySeen[id] or clock) < 10 then
                sticky[id] = addr
            elseif not e or net.remoteEnemies[id] == nil then
                net.stickySeen[id] = nil
            end
        end
        for _, id in ipairs(ids) do
            if matched[id] then
                sticky[id] = matched[id]:GetAddress()
                net.stickySeen[id] = clock
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
                game.stepAside(a.actor, false, a.home)
                game.startAI(a.actor)
            end
        end
        net.aside = keep or {}
    end

    -- A trip, a load or a rest here: every "no" heard is old news (the enemies around have changed), what was put aside comes
    -- back to be asked about afresh, and as host, no "no" is given while this world settles (see HAS).
    function net.unsettle()
        net.unsettledUntil = os.clock() + net.UNSETTLED_S
        net.notOnHost = {}
        pcall(showAside)
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
        local settling = os.clock() < (net.hostSettleUntil or 0)      -- (no new asks: see heard. Those hidden are asked still)
        for _, e in ipairs(own) do
            local name = enemyName(e.actor, e.addr)
            -- (One out of the way waits up high (game.stepAside): where it stood is where it is, for this.)
            local was = net.aside[e.addr]
            local loc = was and was.hidden and was.name == name and was.home or e.loc
            local near = here and name:sub(1, 3) == "sp:" and inReach(loc.X, loc.Y, loc.Z, t) and not game.isDead(e.actor)
                and not net.isDying(e.addr)     -- (417: its death is being shown: not asked after, nor put aside)
            if near and game.isBoss(e.actor, e.addr) then
                local a = net.bossAsk[name] or { since = now, askedAt = -1e9 }
                bosses[name] = a
                if not settling and now - a.since >= ASIDE_AFTER_S and now - a.askedAt >= ASK_AGAIN_S then
                    a.askedAt = now
                    sendEvent("HAS", name)
                end
            elseif near then
                -- (A new enemy at a gone one's address isn't that one: it took its record, stopped and never woke. Nor left
                -- hidden: the record put aside an actor the game brought back at that address, unseen but fighting.)
                local a = net.aside[e.addr]
                if a and a.name ~= name and a.hidden then
                    game.stepAside(e.actor, false, a.home)
                    game.startAI(e.actor)
                end
                if not a or a.name ~= name then
                    a = { actor = e.actor, name = name, since = now, askedAt = -1e9 }
                end
                -- The host's "no" stays good NOT_LIFE_S: one given while its world was still loading (a teleport, a bell) hid
                -- an enemy it had, for good. A hidden one is asked about again now and then, and back if no fresh "no" comes.
                local saidNot = net.notOnHost[name] and now - net.notOnHost[name] < net.NOT_LIFE_S
                if a.hidden and not saidNot then
                    game.stepAside(e.actor, false, a.home)
                    game.startAI(e.actor)
                    a = { actor = e.actor, name = name, since = now, askedAt = -1e9 }
                end
                kept[e.addr] = a
                if a.hidden then
                    if now - (a.aiAt or -9) >= 1 then       -- (once a second: dozens hidden cost calls every round)
                        a.aiAt = now
                        a.brain = game.stopAI(e.actor, a.brain)     -- (the game starts a stopped AI again by itself)
                    end
                    if now - a.askedAt >= ASK_AGAIN_S then
                        a.askedAt = now
                        sendEvent("HAS", name)
                    end
                elseif saidNot and not net.hitHere[name] then   -- (never one this player is fighting)
                    a.hidden = true
                    a.home = { X = e.loc.X, Y = e.loc.Y, Z = e.loc.Z }
                    game.stepAside(e.actor, true, a.home)
                    a.brain = game.stopAI(e.actor)
                    gone = gone + 1
                elseif not settling and now - a.since >= ASIDE_AFTER_S and now - a.askedAt >= ASK_AGAIN_S then
                    a.askedAt = now
                    sendEvent("HAS", name)
                end
            end
        end
        -- (Waiting up high it's out of the list of what's around this player: still out of the way while where it stood is near
        -- the host, or it came straight back down.)
        for addr, a in pairs(net.aside) do
            if not kept[addr] and a.hidden and a.home and here and valid(a.actor) and not game.isDead(a.actor)
                and inReach(a.home.X, a.home.Y, a.home.Z, t)
                and net.notOnHost[a.name] and now - net.notOnHost[a.name] < net.NOT_LIFE_S then
                kept[addr] = a
                if now - (a.aiAt or -9) >= 1 then
                    a.aiAt = now
                    a.brain = game.stopAI(a.actor, a.brain)
                end
                if now - a.askedAt >= ASK_AGAIN_S then
                    a.askedAt = now
                    sendEvent("HAS", a.name)
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
    -- this must not mistake for a heal, so it waits a full second. (In seconds, not rounds: at 30 rounds a second, 20 rounds
    -- were 0.67 s, and posture's 4 were 0.13 s, less than a round trip, so the guest's own posture hits were put back
    -- before the host had heard them and a boss's break never came on the guest's side.)
    local HEAL_TICKS = 1.0
    local HELD_HP = 1             -- the floor the client's copies of host enemies are held at
    net.LETHAL_AGAIN_S, net.LETHAL_TRIES = 0.8, 4   -- a killing blow with no K back is told again this often, this many times
    net.NOT_LIFE_S = 25           -- client: the host's "not in my world" (NOT) is good this long (asked again every ASK_AGAIN_S)
    net.UNSETTLED_S = 10          -- host: no NOT this long after its own load, rest or trip

    -- A copy let go: the hold's floor off it. A guest's copy of a boss standing at that floor isn't let go as it
    -- stands. The floor is this mod's: no finish of the game's own waits on a boss held there, and let go so (a killing
    -- blow of this player's stopped there, the host's own at a floor of its game's, or a line of the host's from before
    -- its world refreshed), the next blow was its death in this world, its pay and all (the bench, 11-18, run207).
    -- r: the host's line of it, where there is one. Said just now, and more than that floor: the host's share of this
    -- copy's most, what the fight had left. Else whole: a host that lists it no more has it whole again itself (its
    -- fight left, its world refreshed), and one that has it at that floor alive, a partner's killing blow not its end,
    -- has it at a floor of its game's own, a finish only that world's player makes. 394.
    net.LET_GO_LINE_S = 2.0
    function net.letGo(actor, addr, r)
        game.setMinHealth(actor, 0)
        local hp, most = game.getHealth(actor)
        if isClient() and hp and most and hp <= HELD_HP + 1.5 and most > HELD_HP + 1.5 and game.setHealth and game.isBoss
            and not (game.isDead and game.isDead(actor)) and game.isBoss(actor, addr) then
            local want = most
            if r and r.at and r.Hp and r.MaxHp and r.MaxHp > 0 and r.Hp > HELD_HP + 1.5
                and (net.frameNow or link.now()) - r.at < net.LET_GO_LINE_S then
                want = math.min(most, most * r.Hp / r.MaxHp)
            end
            game.setHealth(actor, want)
            log(string.format("%s was let go at the floor it was held at (%.0f left): %s, its fight this game's own.",
                enemyName(actor, addr), hp, want < most and string.format("at the host's %.0f", want) or "whole again"))
        end
    end

    -- Guest: this player's own finishing move of a boss, the game's, under way on its copy: an ability of the game's
    -- "BEx" family running on this player, and the copy marked by this game, now or within EXEC_MARK_S, for an
    -- execution at low health (EXEC_MARK, by its whole name: not a Phantom Edge's own mark, which is there at full
    -- health too, nor the mark of an execution on a broken guard, GE_CanWeakExecute, which takes health and ends
    -- nobody). The killing blow that comes inside it is told as that, X, and a host whose game holds that boss at its
    -- last point takes it (handlers.D). A plain killing blow there stays what it was: not its end. The user, 11-18:
    -- "why the guest can't kill the boss by pressing F and playing it's animation he should be able to do that". (The
    -- mark is looked for a second apart on a boss's copy from EXEC_LOW of its health down, syncEnemy: it comes above
    -- the hold's floor, with the blow from 150 to 70 of 28080 on the bench, run184, and a finishing move's one blow
    -- from up there went as a plain one. The tenth review.)
    net.EXEC_MARK, net.EXEC_MARK_S, net.EXEC_LOW = "GE_CanLowHealthExecute_C", 15.0, 0.25
    net.execLookAt, net.execMarkAt = {}, {}
    function net.finishingMove(name, actor, addr)
        if not (game.finishing and game.hasEffect and game.isBoss and game.isBoss(actor, addr)) then
            return false
        end
        local _, pawn = getPlayer1()
        if not (valid(pawn) and game.finishing(pawn)) then
            return false
        end
        return os.clock() - (net.execMarkAt[name] or -1e9) <= net.EXEC_MARK_S or game.hasEffect(actor, net.EXEC_MARK, true)
    end

    -- keep: address -> actor still held this tick (nil releases every held copy).
    local function releaseHeld(keep)
        for addr, actor in pairs(net.heldAlive) do
            if not (keep and keep[addr]) and valid(actor) and game.setMinHealth then
                net.letGo(actor, addr, net.remoteEnemies[enemyName(actor, addr)])
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
        -- (417: one whose death is being shown is nobody's to weigh, report or let go, and its floor stays: left out of
        -- the round's held, releaseHeld lifted it, and this player's next blow ended the copy there and then, its
        -- own pay with it: the bench, run259. net.dieLater ends it.)
        if net.isDying(addr) then
            held[addr] = actor
            return
        end
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
            if api.hitfx then
                api.hitfx.ready()     -- (this player's hits watched before the first lands: hitfx.lua)
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
                -- (Onto its floor by any amount: a copy the host's line left at 1.3 fell to 1 with no report at all, and every
                -- hit after read as nothing, the enemy taking hits for good.)
                local onFloor = net.heldAlive[addr] ~= nil and hp <= HELD_HP + 0.01 and prev.hp > hp + 0.01
                -- (Not with its most health down since the last turn too: this world's own game set its numbers again,
                -- a boss's base written back (Xiao Xue's on the bench, 16482 over co-op's 24723), no blow. Told as one,
                -- it took all of co-op's share off the host's boss at once, a third of her health, and two guests'
                -- at once could end a boss with no blow struck. The sixth review.)
                local written = prev.maxhp ~= nil and maxhp ~= nil and maxhp < prev.maxhp - 1
                -- (Nor a guard bar that fell to stand at its own most: this world's game wrote the most down with it, a
                -- difficulty set again with co-op's health at the game's own, or held a bar over its most to it. No
                -- blow leaves the bar full. Any health it took is weighed as ever. The seventh review.)
                if dPosture > 0.5 and posture ~= nil and game.postureMax
                    and math.abs(posture - (game.postureMax(actor) or math.huge)) < 0.5 then
                    dPosture = 0
                end
                if written and dHp > 0.5 and not net.mine[name] and maxhp > 1
                    and api.scaling and api.scaling.guardKept and api.scaling.guardKept(actor, addr) then
                    -- (Its health alone, its guard bar as it was given: this world's game holds no more than this for it,
                    -- and cuts what's over at each blow of this player's (Xiao Xue's: the bench of 11-18). Put back, every
                    -- blow was cut again and told to nobody. Kept at its game's most from here, its health the share of
                    -- it the host's line says: net.capped, below. The blow that came with the cut is in it, and lost.)
                    net.capped[addr] = { name = name, most = maxhp }
                    hp = math.max(HELD_HP + 1, maxhp * prev.hp / prev.maxhp)
                    if game.setHealth then
                        game.setHealth(actor, hp)
                    end
                    net.stats.undone = net.stats.undone + 1
                    log(string.format("%s's game here holds no more than its own health (%.0f): its copy kept at that.", name, maxhp))
                elseif written and dHp > 0.5 and not net.mine[name] then
                    -- (Put back at once, as a drop not this player's is: the host's line lifts a copy only from 5% under
                    -- and a second on, and one asleep there in this player's own fight never. Left lower, the copy died
                    -- that much sooner, and its killing blow or its death here (GK) took the rest off the host's boss.
                    -- The seventh review.)
                    if game.setMaxHealth then
                        game.setMaxHealth(actor, prev.maxhp)
                    end
                    undoHit(actor, prev.hp, dPosture > 0.5 and prev.posture or nil)
                    hp, maxhp = prev.hp, prev.maxhp
                    posture = dPosture > 0.5 and prev.posture or posture
                elseif (dHp > 0.5 or dPosture > 0.5 or onFloor) and not written then
                    if net.partnerExec and net.partnerExec[name] and not (game.isBoss and game.isBoss(actor, addr)) then
                        undoHit(actor, prev.hp, prev.posture)
                        hp, posture = prev.hp, prev.posture
                    elseif ghostsHit() and (net.pvp or dHp <= 0.5) then
                        -- The host's swing, replayed here: the host's own world already took it.
                        undoHit(actor, prev.hp, prev.posture)
                        hp, posture = prev.hp, prev.posture
                    elseif net.mine[name] then
                        -- (This game runs it: what it loses is real, and the host's copy follows by its lines.)
                    elseif (dHp > 0.5 or onFloor) and not net.pvp and not ownHit(actor) then
                        undoHit(actor, prev.hp, prev.posture)
                        hp, posture = prev.hp, prev.posture
                    else
                        local lethal = net.heldAlive[addr] ~= nil and (dHp > 0.5 or onFloor) and hp <= HELD_HP + 0.01
                        -- (A boss's copy weighs this player's blow as the host's boss does, game.partnerRefuses: no posture in
                        -- the host's break and fill, as it recovers, or while it turns blows aside. Its bar here keeps with the
                        -- host's, and it doesn't break here alone. One this very blow broke is left as its game has it, and the
                        -- blow still goes, posture or none, for the host to judge the break: a parry's break took no health,
                        -- and went nowhere, the guest's boss broken alone.)
                        local hostOf = net.remoteEnemies[name]
                        local broke = false
                        if dPosture > 0.5 and prev.posture and game.partnerRefuses and game.setPosture
                            and not (hostOf and hostOf.Asleep)      -- (asleep there: this game runs its copy, its bar its own)
                            and ((hostOf and hostOf.Boss) or net.partnerBosses[name] or (game.bossTwin and game.bossTwin(actor, addr)))
                            and game.partnerRefuses(actor, addr, true) then
                            local own = game.hitStateOf and game.hitStateOf(actor)
                            broke = own ~= nil and own:find("State.Break", 1, true) ~= nil
                            if not broke then
                                game.setPosture(actor, prev.posture)
                                posture = prev.posture
                            end
                            dPosture = 0
                            net.struck[name] = true     -- (in this fight, a parry's too: see reportHit)
                        end
                        if dHp > 0.5 or dPosture > 0.5 or onFloor or broke then
                            -- (This player's own finishing move, the game's: told as that. net.finishingMove.)
                            local finisher = lethal and net.finishingMove(name, actor, addr) or nil
                            reportHit(name, actor, math.max(0, dHp), math.max(0, dPosture), lethal, finisher)
                            if lethal then
                                net.lethalPending[name] = { at = os.clock(), tries = 1, finisher = finisher }
                                log((finisher and "Finishing move on " or "Killing blow on ") .. name .. "; telling the host.")
                            end
                            -- (A copy kept at its own game's most, net.capped: the blow took that much of the host's, a
                            -- smaller share of what it has. The rest back here, so the copy keeps with the host's.)
                            local cap = net.capped[addr]
                            if cap and cap.name == name and not lethal and dHp > 0.5 and game.setHealth
                                and hostOf and hostOf.MaxHp and hostOf.MaxHp > cap.most + 1 then
                                hp = hp + dHp * (1 - cap.most / hostOf.MaxHp)
                                game.setHealth(actor, hp)
                            end
                        end
                    end
                end
            end
            -- A killing blow told with no K back: told again (a lost or refused one left the copy at 1 health, hit after hit
            -- reading as nothing). The host answers K, or LR with what it has left.
            local pending = net.lethalPending[name]
            if pending and os.clock() - pending.at >= net.LETHAL_AGAIN_S and net.heldAlive[addr] ~= nil then
                if pending.tries >= net.LETHAL_TRIES then
                    net.lethalPending[name] = nil
                    -- (No answer at all: lifted off the floor, so the next blow is a killing blow told again, not nothing.)
                    if game.setHealth and valid(actor) and not game.isDead(actor) then
                        game.setHealth(actor, HELD_HP + 1)
                        hp = HELD_HP + 1        -- (this turn's reading as the copy is now: see seen[] below)
                    end
                else
                    pending.at, pending.tries = os.clock(), pending.tries + 1
                    reportHit(name, actor, 0, 0, true, pending.finisher)
                end
            end
            local r = net.remoteEnemies[name]
            if r then
                -- One of the host's enemies: it dies when the host says so ("K"), never on its own here, so a
                -- killing blow is never played twice and a copy that's a hit ahead doesn't die before the host's.
                -- (Every turn, not once by address: a copy gone and a new one at its address was taken for held already, and
                -- died here on a hit, the host's alive.)
                -- (Not one asleep in the host's world with a guest by it, in a party: this game runs its own copy of
                -- that meanwhile, awake for this player as the game means it, neither held nor steered, and its death
                -- here is this game's own to have and to tell (GK). The next round lets go of the hold and the steering
                -- it had. handover.asleepHere. And only for a player who's by it: handover.byHere.)
                local asleep = r.Asleep == true and handover.byHere(name, actor, addr)
                if asleep and not handover.woken[addr] then
                    handover.wake(name, addr)
                end
                if asleep then
                    -- (Its death here is told, GK, with no blow before it too: a sneak kill, an execution. Told only
                    -- for one this player had hurt, it died here, was told to nobody, and came back. The review of 11-16.)
                    net.hitHere[name] = true
                    handover.rides(name, actor)     -- (what it rides is this game's to run with it: 410)
                end
                local isBossCopy = r.Boss or (game.isBoss and game.isBoss(actor, addr)) or (game.bossTwin and game.bossTwin(actor, addr))
                if game.setMinHealth and not asleep then
                    game.setMinHealth(actor, HELD_HP)
                end
                if not asleep then
                    held[addr] = actor
                end
                -- (A boss's copy low: marked by this game for an execution at low health? Looked at a second apart,
                -- for net.finishingMove.)
                if hp and maxhp and hp <= math.max(HELD_HP + 1.5, maxhp * net.EXEC_LOW) and not asleep
                    and (r.Boss or net.partnerBosses[name]) and os.clock() >= (net.execLookAt[name] or 0) then
                    net.execLookAt[name] = os.clock() + 1.0
                    if game.hasEffect and game.hasEffect(actor, net.EXEC_MARK, true) then
                        net.execMarkAt[name] = os.clock()
                    end
                end
                -- (On its floor with no killing blow told: every blow after read as nothing, and it died only to the host's
                -- hits, "sometimes it can never be killed" (report 1 on 1.6.3). Lifted a point: the bar still reads empty,
                -- and the next blow is a fall onto the floor again, told as the killing blow.)
                if hp and hp <= HELD_HP + 0.01 and net.heldAlive[addr] ~= nil and not net.lethalPending[name]
                    and game.setHealth and not game.isDead(actor) then
                    game.setHealth(actor, HELD_HP + 1)
                    hp = HELD_HP + 1
                end
                if api.puppets and not asleep then
                    api.puppets.follow(name, actor, r)
                end
                if not asleep and (r.Boss or (game.bossTwin and game.bossTwin(actor, addr))) and game.watchBossBar then
                    game.watchBossBar(actor, addr, r.Posture)   -- (the host's bar: its breaks and fills, for this player's blows)
                end
                -- (A copy this world's game holds at no more than its own most, net.capped: kept at that, and the host's
                -- numbers taken as the share of it. Till the host's most is no more than that itself.)
                local cap = net.capped[addr]
                if cap and (cap.name ~= name or not r.MaxHp or r.MaxHp <= cap.most + 1) then
                    net.capped[addr], cap = nil, nil
                end
                local rHp, rMax = r.Hp, r.MaxHp
                if cap then
                    rHp, rMax = r.Hp and r.Hp * cap.most / r.MaxHp, cap.most
                end
                if game.setMaxHealth and rMax and maxhp and math.abs(rMax - maxhp) > 1 then
                    game.setMaxHealth(actor, rMax)
                    maxhp = rMax        -- (what's kept for the next turn: the mod's own write is no write of the game's)
                end
                -- (The most the host's line says, co-op's, for the scaling's own notes of this copy: scaling.lineMost.)
                if r.MaxHp and api.scaling and api.scaling.lineMost then
                    api.scaling.lineMost(addr, r.MaxHp)
                end
                -- (Never below the floor it's held at: the host's line can say 0 before its K comes, and a copy written to 0
                -- reads as dead here without the game's death ever running. The forest's last boss then died in the guest's
                -- world with no scene after it, and the guest's story stayed in the forest while the host's went on.)
                -- (Half a point above it: a copy written to exactly the floor took every blow after with no drop, so none
                -- was ever sent, the enemy the host's alone to finish.)
                -- (A boss asleep there, in its fight here: what it has left is this game's to say, till the host is in.)
                local own = asleep and r.Boss and handover.barOn(addr)
                local want = not own and rHp ~= nil and math.max(rHp, HELD_HP + 0.5) or nil
                if game.setHealth and want ~= nil and hp ~= nil and want < hp - 0.5 then
                    game.setHealth(actor, want)
                    hp = want
                end
                -- (Or full there and not here, by less than that: a lost fight started over, 305, with a blow or two of
                -- this player's on its copy, which stood 3% down for good while the host's was whole. The bench of 11-16.
                -- Not while a killing blow of theirs waits for its answer.)
                local guestFightingAlone = not isBossCopy and (net.struckAt[name] or -1e9) > os.clock() - 4.0
                    and net.target and net.localLoc and gap3d(net.localLoc, net.target) > 3500
                if game.setHealth and not own and not guestFightingAlone and rHp ~= nil and hp ~= nil and rMax
                    and (rHp > hp + math.max(1, rMax * 0.05)
                        or (rHp >= rMax - 0.5 and rHp > hp + 1 and not net.lethalPending[name])) then
                    net.healTicks[name] = net.healTicks[name] or os.clock()
                    if os.clock() - net.healTicks[name] >= HEAL_TICKS then
                        log(string.format("%s healed on the host (%.0f -> %.0f): following.", name, hp, rHp))
                        game.setHealth(actor, rHp)
                        hp = rHp
                        net.healTicks[name] = nil
                    end
                else
                    net.healTicks[name] = nil
                end
                -- (Never down to an empty bar: the host's 0 is a break, its or ours, that fills again. Pulled to 0 after
                -- this game's own break had filled it, every hit of this player's broke the boss again, for good. A boss's
                -- empty is its broken bar as the game holds it, 1.64 of the Gold-Masked One's: pulled down to that, the
                -- copy broke here a second time at this player's next blow.)
                local bars = game.bossBars and game.bossBars[addr]
                local empty = (bars and bars.empty) or (game.POSTURE_EMPTY or 1.5)
                if asleep then
                    net.postureTicks[name] = nil    -- (its bar is its own game's meanwhile: the host's stands still)
                elseif game.setPosture and r.Posture ~= nil and posture ~= nil and r.Posture < posture - 0.5
                    and r.Posture > empty then
                    game.setPosture(actor, r.Posture)
                    posture = r.Posture
                    net.postureTicks[name] = nil
                elseif game.setPosture and r.Posture ~= nil and r.Posture <= empty then
                    net.postureTicks[name] = nil
                elseif game.setPosture and r.Posture ~= nil and posture ~= nil and r.Posture > posture + 0.5
                    and net.postureFull[name] ~= posture then
                    -- (And back up, a few turns on: after the boss's break the bar refills on the host, and here it stayed
                    -- empty for good, as the break never happened here.)
                    -- (Never over its own most: a party's copies keep the most they were scaled to when a player joins
                    -- later, and the host's is raised. Held over it, its game put the bar back at its most at this
                    -- player's next blow, and that blow's guard went to nobody, 375. The eighth review.)
                    -- (Its most read only when the lift is due, and a copy found at it left be till its bar moves: read
                    -- every turn, a party's copies at full asked it 400 times a second with 20 about. The ninth review.)
                    net.postureTicks[name] = net.postureTicks[name] or os.clock()
                    if os.clock() - net.postureTicks[name] >= HEAL_TICKS then
                        local up = math.min(r.Posture, game.postureMax and game.postureMax(actor) or r.Posture)
                        if up > posture + 0.5 then
                            game.setPosture(actor, up)
                            posture = up
                        else
                            net.postureFull[name] = posture
                        end
                        net.postureTicks[name] = nil
                    end
                else
                    net.postureTicks[name] = nil
                end
                net.stats.applied = net.stats.applied + 1
            end
            if net.mine[name] then
                handover.share(name, actor, addr)
            end
            nextSeen[name] = { hp = hp, posture = posture, addr = addr, maxhp = maxhp }
        -- (The old "or (prev and not boss)" here read an undefined global, always nil, so it never did
        -- anything; taken out so it can't start killing copies everywhere that only read dead here.)
        elseif (net.hitHere[name] or net.mine[name])
            and not net.hostKilled[name] and not net.guestKillSent[name] then
            -- It died here before the host had it loaded (we were far apart): the host's copy follows. In a party so does
            -- that of any guest near it. An enemy past the host's reach has no owner: it sleeps on the host, so each guest
            -- by it fights a copy of its own, as a guest alone does, and the first to kill it kills it for everyone.
            -- (Only one this player hit: a copy can read as dead for other reasons, and this would kill it everywhere. Or one
            -- this game ran for the host: its death was this game's own.)
            net.guestKillSent[name] = "own"     -- (this game's own kill: see handlers.K)
            sendEvent("GK", name)
        end
    end

    -- Host, each round: are the two apart, so that the guest's game may run what's clearly nearer the guest?
    function handover.update()
        local now = os.clock()
        if isHost() and now >= (handover.pruneAt or 0) then
            handover.pruneAt = now + 1.0
            for addr, actor in pairs(net.heldAlive) do
                if not valid(actor) or (game.isDead and game.isDead(actor)) then
                    net.heldAlive[addr] = nil
                else
                    local n = enemyName(actor, addr)
                    if not (n and net.guestRuns[n]) then
                        net.heldAlive[addr] = nil
                        if game.setMinHealth and (not game.healthFloor or game.healthFloor(actor) == HELD_HP) then
                            game.setMinHealth(actor, 0)
                        end
                    end
                end
            end
        end
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

    function handover.dragonPillarFight(name)
        return name == "sp:MoTianOld_Seq018-Mask"
    end

    -- Host: a boss the guest is fighting (its B) and this player isn't is the guest's game's to run, wherever the two stand.
    -- This game wakes a boss for its own player alone, once they're in its arena, and past some 45 m of them slows it to a
    -- stop or puts it away with its camp. So a guest who went in first, the host on its way, outside the wall or back at a
    -- bell, fought a boss this game had brought out for the fight and never woken: their own stood with it, bar up, and
    -- never swung ("my friend is host and i guest, the boss cant hit me", 11-15; the bench, 11-16: 15 hits in 25 s with the
    -- host by it, none with the host 70 m off). It's this game's again the moment this player is in a fight (E at the wall,
    -- F3, its own bar, the boss going for them), with the health the guest's game last said it had left.
    function handover.bossGoes(name, actor, runs)
        local t = net.target
        if net.party or net.pvp or t == nil or net.partnerGone or not sameMap(t) or net.localLoc == nil
            or name:sub(1, 3) ~= "sp:" or not net.partnerBosses[name] then
            return false
        end
        return runs or (os.clock() >= (handover.retryAt[name] or 0) and not (game.isDead and game.isDead(actor)))
    end

    -- Host: this player is in that boss's fight: walked into the guest's (E at the wall, F3), the game's own bar up on it
    -- here (its fight began in this game too), or a blow of theirs landed from near it. dh: how far it is from them.
    function handover.hostIn(name, addr, dh)
        -- This Dragon Pillar arena can be entered before the host's own sequence starts its boss. Until its own bar
        -- arrives, joining or hitting the mirrored body doesn't give the host a running encounter to take over.
        if (net.party or not handover.dragonPillarFight(name))
            and (net.joinedBoss == name or (net.struck[name] and dh <= handover.FIGHT_CM)) then
            return true
        end
        -- (No bar marked at this address, a table's look: nothing to walk. A party's guest asks this of each copy asleep
        -- on the host at each of its turns, and each walk read a name and a death for every bar up. The third review.)
        if game.bossAt and not game.bossAt(addr) then
            return false
        end
        for _, boss in ipairs(game.bossActors and game.bossActors() or {}) do
            if boss:GetAddress() == addr and not (game.isMirrorBar and game.isMirrorBar(boss)) then
                return true
            end
        end
        return false
    end

    -- Host of a party: an enemy this game has asleep with a guest by it, which each guest's game runs a copy of for
    -- itself meanwhile. A party has no handing over (its relay carries enemy lines from the host alone), but this game
    -- wakes enemies for its own player alone all the same: with three or more players, one by a guest some way from the
    -- host stood asleep here, and so on every guest's screen, a boss a guest went in to first too (104 and 263, as they
    -- were for two). Its line says so (the boss field: 2, and 3 for a boss), and while it does a guest's copy is neither
    -- held nor steered: it wakes there as the game means it to, for the guest who's by it, and its death there is told
    -- (GK) and is its death everywhere. Its health is still this world's: every guest's blows come here, and its line
    -- takes each copy down with it. What it does is each guest's own to see: two guests by the same one, away from the
    -- host, fight a copy each.
    -- Asleep by the two players' rule (104): a guest over 25 m from this player (together again within 15), the enemy
    -- within that guest's 60 m and 10 m nearer them; never one after this player from within 30 m, and none new while this
    -- player's own boss bar is up. And one in a guest's boss fight that this player isn't in, wherever they stand. (By
    -- the optimizer's own 45 m first: on the bench, 11-16, the elite of Xigu stood 44.9 m from the host, the guest beside
    -- it: never woken there, never called asleep, and no blow at the guest in 40 s.)
    function handover.asleepHere(name, actor, addr, x, y, z, boss)
        local was = handover.asleep[name] == true
        local yes = false
        if net.party and not net.pvp and net.localLoc and name:sub(1, 3) == "sp:" then
            local dh = handover.dist(x, y, z, net.localLoc)
            local theirs = net.partnerBosses[name] ~= nil
            -- (For this player's own fight only one within its reach: a guest's boss further off, as this player fought
            -- another, stood asleep and held for nobody. And never one held up by a floor of the game's own: its end is
            -- its script's here, 193. The review of 11-16.)
            if (boss or theirs) and ((net.toldFighting and dh <= ENEMY_RADIUS_CM) or handover.hostIn(name, addr, dh)
                or (game.healthFloor and game.healthFloor(actor) >= 1)) then
                yes = false
            elseif theirs then
                yes = true
            elseif was or not net.toldFighting then
                for _, p in ipairs(partners()) do
                    local t = p.target
                    if t ~= nil and not p.ghostHidden and not p.partnerGone and sameMap(t)
                        and gap3d(net.localLoc, t) > (was and handover.TOGETHER_CM or handover.APART_CM) then
                        local dg = handover.dist(x, y, z, t)
                        if (was and dh + handover.NEARER_CM >= dg)
                            or (not was and dg <= ENEMY_RADIUS_CM and dg + handover.NEARER_CM < dh) then
                            yes = true
                            break
                        end
                    end
                end
                -- (Never one after this player from within 30 m: asked last and of a candidate alone, a call into the game.)
                if yes and dh <= handover.FIGHT_CM and game.enemyAfterSlot
                    and game.enemyAfterSlot(actor, net.ghostSlots) == 1 then
                    yes = false
                end
            end
        end
        if yes ~= was then
            handover.asleep[name] = yes or nil
            log(name .. (yes and " sleeps here with a guest by it: each guest's game runs its own copy of it."
                or " is awake here again: this game's to run for everyone."))
        end
        return yes
    end

    -- A boss bar of any kind is up here on the actor at this address.
    function handover.barOn(addr)
        for _, boss in ipairs(game.bossActors and game.bossActors() or {}) do
            if boss:GetAddress() == addr then
                return true
            end
        end
        return false
    end

    -- Host, an enemy's turn: true while the guest's game runs it. It's handed over, or taken back, as where it is says.
    -- (The host down in a boss fight, the guest still up and by that boss: the boss is the guest's game's
    -- to run till the host is up again. Left with the host, it went after the guest's ghost there, which no blow can
    -- touch, and the guest's copy only replayed that: the boss stood by the guest swinging at nothing, or not at all,
    -- and never hurt them (the gold-masked man, 11-23). In the guest's game it fights the guest itself.
    -- handover.HOST_DOWN_GIVES = false turns this off.)
    -- (Off as it ships in 1.7.6: with it on, a boss that falls while the host is down dies by the guest's own game and
    -- reaches the host as that guest's kill, and what the host is owed for such a fall (its dust, its items, the win's
    -- steps of the story: 334, 383, 388) is proven only for a fall told by the host's own game. The sim's check of
    -- it, "a boss, then a death that rolls nothing 0.3 s on, the host down", paid nobody with this on. To turn on
    -- once that way is proven too.)
    handover.HOST_DOWN_GIVES = false
    function handover.hostDownFor(x, y, z)
        if handover.HOST_DOWN_GIVES == false or not isHost() or net.deadSince == nil or net.party or net.pvp then
            return false
        end
        local t = net.target
        if t == nil or net.ghostHidden or net.partnerGone or not sameMap(t) then
            return false
        end
        return handover.dist(x, y, z, t) <= handover.FIGHT_CM
    end

    function handover.guestRuns(name, actor, addr, x, y, z)
        local runs = net.guestRuns[name] == true
        if x == nil or x ~= x or y ~= y or z ~= z then
            return runs
        end
        local want = false
        local boss = game.isBoss and game.isBoss(actor, addr)
        local dh = net.localLoc and handover.dist(x, y, z, net.localLoc) or 0
        -- (In its fight, or by this player in a fight of theirs with it still this game's: it stays, whatever the guest
        -- does. One further off is in no fight here: a guest's at another boss, as this player fought their own, stood
        -- held, asleep here, till that fight was over. And one held up by a floor of the game's own stays, its fight this
        -- world's to finish (193): not handed over yet, a floor on it here is the game's; handed over it lost it, and a
        -- guest's kill was then its death outside its script here. The review of 11-16.)
        if boss and handover.hostDownFor(x, y, z) and not (game.isDead and game.isDead(actor)) then
            want = true
        elseif boss and (handover.hostIn(name, addr, dh) or (not runs and ((net.toldFighting and dh <= ENEMY_RADIUS_CM)
            or (game.healthFloor and game.healthFloor(actor) >= 1)))) then
            want = false
        elseif boss and handover.bossGoes(name, actor, runs) then
            want = true
        -- (Nothing new handed over while either player's boss bar is up: an arena's other fighters and a boss the codex
        -- doesn't call one, the gold-masked man of the first map, went to the guest's game mid-fight, and the host's own
        -- copy stood held at 1 health with its AI off.)
        elseif handover.on and name:sub(1, 3) == "sp:" and (runs or not (net.toldFighting or net.partnerFighting)) then
            local dg = handover.dist(x, y, z, net.target)
            if runs then
                want = dh + handover.NEARER_CM >= dg
            else
                -- (Within the guest's own reach: its game has it near, and sends what it does.)
                -- (A boss in no fight too: this game wakes one for its own player alone, as they walk into its arena, and
                -- one the guest walked up to first stood asleep here, its copy with it, the host 45 m behind: the bench,
                -- 11-16. In the guest's game it wakes as the game means it to.)
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

    -- One that just changed hands has its own AI back (puppets.release), and is looked at from then on. The game runs an
    -- enemy's fight as one short tree after another, and a tree stopped while its copy followed the other game's can leave
    -- that chain waiting for good: on the bench (11-16) a boss the host's game took back as its own fight with it began
    -- stood beside the host in its fight, its tree stopped, till the tree was started by hand, and went still again after
    -- each move. So one found in a fight with its tree stopped and no move playing, at two looks running a second apart,
    -- has it started again (game.startAI), for as long as it lives and is this game's. Not in a scene, and never one in a
    -- move: the game stops a tree itself for those.
    handover.WAKE_S = 600
    handover.woken = {}         -- enemy address -> { name, untilAt, stopped }
    -- A montage up on it: a move, a flinch. (puppets.inMove knows only what this PC sends of an enemy, and a party's guest
    -- sends nothing of one asleep on the host, which its game runs all the same: its tree was started again in the
    -- middle of its own moves. The review of 11-16.)
    function handover.moving(actor)
        local on = false
        pcall(function()
            local ai = api.moves and api.moves.animOf(actor)
            on = ai ~= nil and valid(ai:GetCurrentActiveMontage())
        end)
        return on
    end
    function handover.wake(name, addr)
        handover.woken[addr] = { name = name, untilAt = os.clock() + handover.WAKE_S, stopped = 0 }
    end

    -- Guest of a party: one asleep on the host is this game's to run a copy of for a player who's by it. Every guest with
    -- it loaded ran one, and a partner's figure beside a copy was enough to rouse it: a guest fought the elite of Xigu
    -- alone, and the copy of a third player 43 m off at the bell was in a fight of the game's own with that player
    -- within 3 s. They counted as in the boss fight (the fighter, down, waited on them to respawn, and the boss didn't
    -- start over: 305), and five minutes on it had walked up to them. The bench of 11-16, three copies. By it: within 30 m,
    -- or in its fight (walked in, its own bar here, a blow from near it). One this game runs stays its own within the
    -- game's own 45 m, and past them while it's still fighting here. Any other copy is held and follows the host's, as
    -- before 277. (No "within 45 m with nobody nearer it": tried, and on the bench the copy of a watcher 42 m off woke
    -- all the same as the fighter stepped in, their figure hidden for that moment.)
    -- A held copy left in a fight's state from before is put back to idle, the game's own way (game.calmCopy): the game
    -- starts a stopped AI again by itself, and in that moment such a copy took its own player on, bar and all, 42 m off
    -- (the bench: the elite's three, who had fought each other as the world loaded). And its own bar here says "in its
    -- fight" for a copy that's this game's already, or for the player nearest it (their own fight, begun by the game from
    -- further off): not for a watcher's, whose bar comes of such a moment. Nearest by where each was last told to be,
    -- shown or not; whether a partner's fight is told yet is no test (the watcher's bar came first, on the bench).
    handover.BY_CM, handover.BY_FAR_CM, handover.STRUCK_S = 3000, 4500, 5
    handover.live = {}          -- guest: enemy address -> its name, while this game runs its own copy of it
    -- (Any partner nearer, in a fight or not: the one about to fight, 35 m off and not told yet, is nearer than a
    -- watcher whose stray bar comes then. Counted only within 30 m or in a fight, the watcher's copy was made theirs
    -- and told, and the fighter's lost fight never started over. A guest's own fight begun from further off, a
    -- partner nearer, waits till they're within 30 m; its B is held till then (announceBoss) if it sleeps on the host:
    -- told, 344's "no fight" ends it 4 s on. The fourth review.)
    function handover.nobodyNearer(at, gap)
        for _, p in ipairs(partners()) do
            local t = p.target
            if t ~= nil and not p.partnerGone and sameMap(t) and handover.dist(at.X, at.Y, at.Z, t) < gap then
                return false
            end
        end
        return true
    end
    handover.calm = {}          -- guest: enemy address -> { at: when a held copy's state is looked at next, n: times calmed }
    function handover.byHere(name, actor, addr)
        local was = handover.live[addr] == name
        local near = reach.near[addr]
        local yes, own = was, false
        if near and net.localLoc then
            local at = near.loc
            local gap = handover.dist(at.X, at.Y, at.Z, net.localLoc)
            own = handover.hostIn(name, addr, gap)
            -- (Nearest, for the race it was made for: no partner's fight told yet. With one told, a stray bar is that
            -- fight's mirror again whoever is nearest: the fight had moved away from where the boss sleeps on the host,
            -- where a held copy stays, and the watcher 43 m off was the nearest to theirs. The third review.)
            -- (And one this player struck from within the game's own 45 m, no partner's fight on: theirs, whoever's
            -- nearer. Held, the blows of one 40 m off, a thrown blade's or a cannon's, went to the host and wore the
            -- boss down while its copy stood still, nobody in its fight. A stray bar is no blow. The fifth review.)
            -- (A blow of the last few seconds, not the mark, which stays till a death or a rest: one who struck it,
            -- walked off alive and came back 43 m from it had their copy woken before any bar, a nearer partner about
            -- to fight it; its stray bar then told the fight as theirs, the fighter's own untold, and as they left it
            -- ended the fighter's on the host. The sixth review.)
            yes = gap <= (was and handover.BY_FAR_CM or handover.BY_CM) or net.joinedBoss == name
                or (own and (was or (net.partnerBosses[name] == nil and handover.nobodyNearer(at, gap))))
                or ((net.struckAt[name] or -1e9) > os.clock() - handover.STRUCK_S and gap <= handover.BY_FAR_CM
                    and net.partnerBosses[name] == nil)
            local now, c = os.clock(), handover.calm[addr]
            -- (A partner's fight with it shown here: its copy isn't calmed meanwhile. Calmed, the game ended "its fight"
            -- and took the bar down, the mirror with it: the watcher saw no bar for the fight. The bench.)
            local theirs = not yes and not was and net.partnerBosses[name] ~= nil
            if not yes and own and game.mirrorBar then
                -- (The game's own bar on a copy that isn't this game's to run: the stray of an AI started for a moment.
                -- A partner's fight's mirror again; or, no such fight on, taken down and the copy calmed now.)
                game.mirrorBar(actor, theirs)
                if not theirs then
                    c = nil
                end
            elseif theirs and not handover.barOn(addr) and now >= (net.quietUntil or 0)
                and now >= (handover.reshownAt or 0) then
                -- (Their fight's bar, gone with a stray before the fight was told. Once a second at most, and not in
                -- the quiet after a load: each is a search of the HUD and of every fog wall, and with no HUD to put it
                -- on, mid-load, it went again at every turn. The third review.)
                handover.reshownAt = now + 1.0
                mirrorBossFight(name, actor)
            end
            if not yes and not theirs and (was or now >= (c and c.at or 0)) then
                local state = game.aiState and game.aiState(actor)
                local fighting = state ~= nil and state:find("Combat", 1, true) ~= nil
                if was then
                    yes = fighting      -- (past the 45 m and still fighting here: the game's to end)
                else
                    c = c or { n = 0 }
                    handover.calm[addr] = c
                    c.at = now + 1.0
                    if fighting and game.calmCopy and game.calmCopy(actor) then
                        -- (Less and less often: one with a fight of its own in this world, its fellows', is in it again
                        -- at once, and was calmed and said so every second.)
                        c.n = c.n + 1
                        c.at = now + math.min(30, 2 ^ c.n)
                        if c.n == 1 then
                            log(name .. " is held here in a fight's state from before: put back to idle.")
                        end
                    end
                end
            end
        end
        handover.live[addr] = yes and name or nil
        -- (Only with the game's own bar on it: hostIn says yes for a blow from near it too, and a guest who struck one
        -- with no bar, went off past 45 m and came back told a fight nobody was in. The fourth review.)
        if yes and not was and handover.barOn(addr) and not (game.isMirrorBar and game.isMirrorBar(actor))
            and not (net.ownAnnounced or {})[name] and api.coop and api.coop.announceBoss then
            api.coop.announceBoss(actor)    -- (its fight, held back while the copy wasn't this game's: announceBoss)
        end
        return yes
    end
    function handover.stayAwake()
        local now = os.clock()
        if now < (handover.wakeLookAt or 0) then
            return
        end
        handover.wakeLookAt = now + 1.0
        for addr, w in pairs(handover.woken) do
            local e = reach.near[addr]
            local actor = e and e.actor
            if not valid(actor) or now > w.untilAt or enemyName(actor, addr) ~= w.name or (game.isDead and game.isDead(actor))
                or (api.puppets and api.puppets.follows(addr)) then
                handover.woken[addr] = nil
            else
                local state = game.aiState and game.aiState(actor)
                if game.aiStopped and game.aiStopped(actor) and (state == nil or state:find("Combat", 1, true))
                    and not (api.puppets and api.puppets.inMove(w.name)) and not handover.moving(actor)
                    and not (game.inCutscene and game.inCutscene()) then
                    w.stopped = w.stopped + 1
                    if w.stopped >= 2 then
                        w.stopped = 0
                        game.startAI(actor)
                        w.starts = (w.starts or 0) + 1
                        if w.starts == 1 then
                            log(w.name .. " stood in its fight with its AI stopped after changing hands: started again.")
                        end
                    end
                else
                    w.stopped = 0
                end
            end
        end
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
            -- (The hold's own floor alone: one the game set meanwhile, a phase's, is its script's to keep. 193.)
            if valid(actor) and game.setMinHealth and (not game.healthFloor or game.healthFloor(actor) == HELD_HP) then
                game.setMinHealth(actor, 0)
            end
        end
        if api.puppets then
            api.puppets.release(addr)
        end
        handover.wake(name, addr)
    end

    -- Host: it died, whoever ran it. Nothing steers it now.
    function handover.drop(actor, addr, name)
        net.guestRuns[name], net.guestLines[name], handover.seen[name] = nil, nil, nil
        net.heldAlive[addr] = nil
        if api.puppets then
            api.puppets.drop(actor)
        end
    end

    -- Host: a partner's fight that this player isn't in is over with its boss alive: they died in it, or left it. It
    -- starts over, as a lost fight does in the game: the boss back to full health here, and this game's to run again
    -- first (one the guest's game still ran had its next line take it down again). Left as it was, the guest's world
    -- brought its boss back at full and this world's line took the new copy down to where the last try ended: a retry
    -- begun at 30%, easier than the game, and to be had by dying. Since a boss the guest went in to first is the guest's
    -- game's to run (263), and in a party one asleep here (277), that was the ordinary case. Not with PvP on or in a
    -- match, as a sit's; in a party not while another's fight is on. The review of 11-16.
    function handover.lost(name)
        local actor = enemyByName[name]
        if not valid(actor) and game.liveBossesWithId then
            actor = game.liveBossesWithId(name)[1]      -- (out of this round's reach: its guest back at a far bell)
        end
        if not isHost() or net.pvp or net.arena or (net.party and net.partnerFighting) or not valid(actor)
            or (game.isDead and game.isDead(actor)) then
            return
        end
        if net.guestRuns[name] then
            handover.retryAt[name] = os.clock() + handover.RETRY_S
            handover.give(name, actor, actor:GetAddress(), false)
        end
        if net.bossFull(actor) then
            log("The other player's fight with " .. name .. " is over with the boss alive: it starts over at full health.")
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
        -- (Held, and its hits weighed, from the handover on, not from the guest's first line: in that round trip the host's
        -- hits on it went untold, and the guest's health took them back.)
        if game.setMinHealth then
            net.heldAlive[addr] = actor     -- (each turn: the actor at an address can be a new one, see syncEnemy)
            game.setMinHealth(actor, HELD_HP)
        end
        -- A drop since the last turn is weighed as a guest weighs one on its copies of the host's (syncEnemy).
        local prev = handover.seen[name]
        local _, maxhp = game.getHealth(actor)
        if prev and prev.addr == addr and prev.hp and hp then
            local dHp = prev.hp - hp
            local dPosture = (prev.posture and posture) and (prev.posture - posture) or 0
            -- (Onto its floor by any amount, as syncEnemy weighs it: a blow onto the floor of half a point or less was told
            -- to nobody, and every blow after read as nothing, the host unable to finish it till the guest did.)
            local onFloor = hp <= HELD_HP + 0.01 and prev.hp > hp + 0.01
            -- (Not with its most health down too: this world's own game set its numbers again, as syncEnemy has it,
            -- and they're put back at once. Nor a guard bar that fell to stand at its own most.)
            local written = prev.maxhp ~= nil and maxhp ~= nil and maxhp < prev.maxhp - 1
            if dPosture > 0.5 and posture ~= nil and game.postureMax
                and math.abs(posture - (game.postureMax(actor) or math.huge)) < 0.5 then
                dPosture = 0
            end
            if written and dHp > 0.5 then
                if game.setMaxHealth then
                    game.setMaxHealth(actor, prev.maxhp)
                end
                undoHit(actor, prev.hp, dPosture > 0.5 and prev.posture or nil)
                hp, maxhp = prev.hp, prev.maxhp
                posture = dPosture > 0.5 and prev.posture or posture
            elseif (dHp > 0.5 or dPosture > 0.5 or onFloor) and not written then
                if (ghostsHit() and dHp <= 0.5) or ((dHp > 0.5 or onFloor) and not ownHit(actor)) then
                    undoHit(actor, prev.hp, prev.posture)
                    hp, posture = prev.hp, prev.posture
                else
                    local lethal = (dHp > 0.5 or onFloor) and hp <= HELD_HP + 0.01
                    reportHit(name, actor, math.max(0, dHp), math.max(0, dPosture), lethal)
                    if lethal then
                        net.hostLethal[name] = true     -- (its items are rolled here when the death comes back: GK)
                    end
                end
            end
        end
        if r == nil then
            handover.seen[name] = { hp = hp, posture = posture, addr = addr, maxhp = maxhp }
            return true             -- (the guest's first line is on its way)
        end
        if api.puppets then
            api.puppets.follow(name, actor, r)
        end
        if game.setMaxHealth and maxhp and math.abs(r.MaxHp - maxhp) > 1 then
            game.setMaxHealth(actor, r.MaxHp)
            maxhp = r.MaxHp
        end
        -- (Never below half a point over its floor, as syncEnemy writes it, and lifted off the floor with no killing blow
        -- told: written to the guest's 1.2, a blow after read as nothing.)
        local want = math.max(r.Hp, HELD_HP + 0.5)
        if hp and want < hp - 0.5 then
            game.setHealth(actor, want)
            hp = want
        elseif hp and hp <= HELD_HP + 0.01 and not net.hostLethal[name] then
            game.setHealth(actor, HELD_HP + 1)
            hp = HELD_HP + 1
        elseif hp and r.Hp > hp + math.max(1, r.MaxHp * 0.05) then
            net.healTicks[name] = net.healTicks[name] or os.clock()
            if os.clock() - net.healTicks[name] >= HEAL_TICKS then
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
        handover.seen[name] = { hp = hp, posture = posture, addr = addr, maxhp = maxhp }
        return true
    end

    -- Guest, the turn of one this game runs for the host: where it is and what it does go to the host's game, as the host's
    -- enemies come here.
    -- Guest: one this game runs (handed over, or asleep on a party's host with this player by it): what it rides is
    -- this game's to run with it. Its mount's address is noted every MOUNTS_S, and matchRemoteEnemies leaves that one
    -- unpaired while the note is fresh. 410.
    function handover.rides(name, actor)
        if game.mountOf and os.clock() >= (handover.mountAt[name] or 0) then
            handover.mountAt[name] = os.clock() + net.MOUNTS_S
            local mount = game.mountOf(actor)
            if mount then
                handover.mineMounts[mount] = os.clock()
            end
        end
    end

    function handover.share(name, actor, addr)
        handover.rides(name, actor)
        local x, y, z, yaw, vx, vy, _, _, hp, maxhp, posture = game.read(actor, addr)
        if hp and maxhp and maxhp > 0 and x == x and y == y and z == z and yaw == yaw then
            local number = enemyNumber(actor, name)
            net.sendEnemyLine(number, string.format("%d %.0f %.0f %.0f %.0f %.0f %.0f %.1f %.1f 0 %s", number,
                x, y, z, yaw, vx == vx and vx or 0, vy == vy and vy or 0, hp, maxhp,
                posture ~= nil and string.format("%.1f", posture) or "-"))
        end
        if api.hitfx and hp then
            api.hitfx.runs(name, actor, addr, hp)     -- (this player's own hits on it, for everyone else: hitfx.lua)
        end
        if api.puppets then
            api.puppets.watchHost(name, actor, addr)
        end
        if handover.dragonPillarFight(name) and game.hateGhost and x and os.clock() >= (handover.dragonAggroAt or 0)
            and not game.isDead(actor) and not game.inCutscene() then
            handover.dragonAggroAt = os.clock() + AGGRO_S
            aggroParty(actor, addr, x, y, z, hp, name)
        end
    end

    -- Everything handed over goes back: sync off or on again, the partner gone or started anew, a rest, another map.
    function handover.reset()
        if isHost() then
            for _, actor in pairs(net.heldAlive) do
                -- (The hold's own floor alone, as release's.)
                if valid(actor) and game.setMinHealth and (not game.healthFloor or game.healthFloor(actor) == HELD_HP) then
                    game.setMinHealth(actor, 0)
                end
            end
            net.heldAlive = {}
            if api.puppets then
                api.puppets.releaseAll()        -- (a host's puppets are only ever the ones a guest's game ran)
            end
        end
        net.guestRuns, net.guestLines, net.mine = {}, {}, {}
        handover.seen, handover.since, handover.retryAt, handover.on, handover.woken = {}, {}, {}, false, {}
        handover.asleep, handover.live, handover.calm = {}, {}, {}
        handover.mountAt, handover.mineMounts = {}, {}
        handover.dragonAggroAt = nil
    end

    local function startHostRound(now)
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        handover.stayAwake()
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
        AFTER_S = 0.6,
        AGAIN_S = 6.0,
        AGAIN_MOST = 30,
        PER_ROUND = 6,
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
        -- A boss the host said died, alive again in its lines: up again on the host (Xiaoxue at the Mass Grave, a boss whose
        -- fight goes on after a fall). Its copy here had died with it, and the fight went on with nothing on this player's
        -- screen, the host's alone to finish and be paid for. Spawned again here, as for a fight.
        for name, r in pairs(net.remoteEnemies) do
            if enemyByName[name] == nil and r.Boss and (r.Hp or 0) > 0 and net.hostKilled[name] and name:sub(1, 3) == "sp:"
                and net.bossFell and net.bossFell[name] and now - net.bossFell[name] < 600
                and distance(net.localLoc, r) <= PARTNER_REACH_CM and asked < bring.PER_ROUND and game.spawnBoss then
                local b = net.bringing[name] or { since = now, askedAt = -1e9 }
                net.bringing[name] = b
                if now - b.since >= bring.AFTER_S and now - b.askedAt >= bring.AGAIN_S then
                    b.askedAt = now
                    asked = asked + 1
                    local at, turned, spawned = game.spawnBoss(name, true)
                    if at then
                        -- (Its death cleared only once it's up again: a failed spawn is tried again next round.)
                        net.hostKilled[name], net.pendingDeaths[name] = nil, nil
                        net.broughtBack[name] = turned or net.broughtBack[name]
                        if type(spawned) == "table" then
                            spawned.untilAt = os.clock() + 120
                            net.extraBossWatch = net.extraBossWatch or {}
                            net.extraBossWatch[name] = spawned
                        end
                        -- (The host still in its fight, its bar up through the fall: no new B comes, and this copy stood with
                        -- no bar or walls, its death at the host's kill a quiet one: no scene, no story step, no reward here.)
                        local hostFights = net.party and peerOf(nil).fights or (not net.party and net.partnerFighting)
                        if hostFights then
                            net.partnerBosses[name], net.hostBosses[name], net.pendingBosses[name] = true, true, true
                            if net.party then
                                net.fightOf[name] = 1
                            end
                        end
                        log("Boss " .. name .. " is up again on the host: back here too.")
                    end
                end
            end
        end
        -- The boss of a fight of the host's that this player came to late (F3, or walking in): spawned when the fight began only
        -- if its arena was loaded here then, and never after, so they fought nothing, or an enemy paired in its place (player
        -- report 11-09). Spawned now that they're by it.
        for name in pairs(net.pendingBosses) do
            local r = net.remoteEnemies[name]
            if enemyByName[name] == nil and r and r.Boss and (r.Hp or 0) > 0 and net.partnerBosses[name] and not net.hostKilled[name]
                and name:sub(1, 3) == "sp:" and distance(net.localLoc, r) <= PARTNER_REACH_CM and asked < bring.PER_ROUND
                and game.spawnBoss then
                local b = net.bringing[name] or { since = now, askedAt = -1e9 }
                net.bringing[name] = b
                if now - b.since >= bring.AFTER_S and now - b.askedAt >= bring.AGAIN_S then
                    b.askedAt = now
                    asked = asked + 1
                    local at, turned, spawned = game.spawnBoss(name, true)
                    if at then
                        net.broughtBack[name] = turned or net.broughtBack[name]
                        if type(spawned) == "table" then
                            spawned.untilAt = os.clock() + 120
                            net.extraBossWatch = net.extraBossWatch or {}
                            net.extraBossWatch[name] = spawned
                            -- (As joinBossFight's: one still standing when the fight ends goes, no death.)
                            if spawned.addr then
                                net.spawnedFor = net.spawnedFor or {}
                                net.spawnedFor[name] = { addr = spawned.addr, fname = spawned.fname, class = spawned.class }
                            end
                        end
                        log("The host's fight with " .. name .. " came here late: its boss spawned here now.")
                    end
                end
            end
        end
        -- (Within this player's own reach only, where a copy is paired with the host's and held from its first turn. It was
        -- 120 m: one further off than the 60 m a copy is paired within read as missing for good, and was asked for every
        -- 10 s. In a party the host's lines reach every guest, so a guest had the camp another guest stood by, 95 m off,
        -- brought back again and again; on the bench, 11-16, three copies, each one brought back there was dead a few
        -- seconds on and paid that player its dust, shared on: 330 to everyone every 20 s, for ten minutes. And asked again
        -- less and less often: whatever takes a copy away, it's no way to dust.)
        for name, r in pairs(net.remoteEnemies) do
            -- (Not one named by a spawner its game made as it ran, an older host's word for a mount: no spawner here goes
            -- by that name, and each ask was a search of them all. 410.)
            if enemyByName[name] == nil and not r.Boss and (r.Hp or 0) > 0 and name:sub(1, 3) == "sp:" and not net.hostKilled[name]
                and not net.ownName(name) and r.X ~= nil and inReach(r.X, r.Y, r.Z, net.localLoc) then
                local b = net.bringing[name] or { since = now, askedAt = -1e9, tries = 0 }
                net.bringing[name] = b
                local again = bring.AGAIN_S * math.min(2 ^ (b.tries or 0), bring.AGAIN_MOST)
                if now - b.since >= bring.AFTER_S and now - b.askedAt >= again and asked < bring.PER_ROUND then
                    b.askedAt = now
                    asked = asked + 1
                    local ok, wasDead = game.bringBack(name)
                    if ok then
                        back = back + 1
                        b.tries = (b.tries or 0) + 1
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
                end
                if game.markBeaten then
                    game.markBeaten(name)
                end
            end
        end
    end

    -- Client: what bringBack turned back in this save's records goes back as it was.
    function bring.putBackAll()
        if game.putBack and next(net.broughtBack) then
            game.putBack(net.broughtBack)       -- (those not loaded now stay owed: game.owed, tried again later)
        end
        net.broughtBack, net.bringing = {}, {}
    end

    -- Records still owed (their spawner wasn't loaded when they were to be put back) are tried again every few seconds, sync
    -- on or off, leaving out those a session uses right now. (Its own loop: coop's ticks stop with sync.)
    if type(LoopInGameThreadWithDelay) == "function" then
        LoopInGameThreadWithDelay(5000, function()
            if game.owed and next(game.owed.ids) then
                -- (Not one this session has here or is bringing: alive in both worlds for this session, it was written
                -- dead under the host's living enemy.)
                local keep = {}
                for id in pairs(net.broughtBack) do
                    keep[id] = true
                end
                if net.enabled then
                    for id in pairs(net.bringing or {}) do
                        keep[id] = true
                    end
                    for id in pairs(enemyByName) do
                        keep[id] = true
                    end
                end
                pcall(game.owed.retry, keep)
            end
            return false
        end)
    end

    local function startGuestRound(now)
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        handover.stayAwake()
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
        -- (An enemy that stands still has a line only every net.enemySameS: two of those on top, or one went before the link
        -- was even called quiet.)
        for name, r in pairs((linkQuiet or settling) and {} or net.remoteEnemies) do
            if now - r.at > ENEMY_STALE_S + 2 * net.enemySameS then
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
            if round.at > #round.queue and now - round.startedAt >= (net.enemyRoundS or ENEMY_ROUND_S) then
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
            local specTarget = game.isSpectating and game.isSpectating() and t or nil
            updateReach(origin, specTarget, dt)
            if round.at > #round.queue and now - round.startedAt >= (net.enemyRoundS or ENEMY_ROUND_S) then
                startGuestRound(now)
            end
        end
        -- Whatever share of the round this frame stands for.
        local turns = math.ceil(#round.queue * math.max(dt, 0.004) / (net.enemyRoundS or ENEMY_ROUND_S))
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

    -- A step of the other side's enemy that nothing runs: over JUMP_CM between two of its lines, and either faster
    -- than JUMP_CMS or from standing still to standing still. A teleport, or a dash that is one in all but name: on
    -- the bench, 11-20 (run251, A-Hua, her place every frame on both copies), her teleport move goes 5 to 6 m at 75
    -- to 90 m a second, 150 to 390 cm between two lines, where her fastest plain attack goes 90 and a charging
    -- horse 140; her blinks go 14 and 17 m at once. A copy further than SNAP_CM from its line is set there, and
    -- that covered the blinks. Nearer, it was walked there at a copy's 14 m a second and nudged: after each such
    -- move the guest's copy was 4 to 7 m behind the host's boss and took 0.5 to 0.7 s to come, her blow struck
    -- meanwhile from where the host had her ("boss teleport doesn't sync up for guest ... near impossible for guest
    -- to fight", players on 1.7.4). The line's record says when, and which way: puppets.lua's steer sets the copy
    -- there. (Fields of net: this function is at Lua's 200 locals.) 411.
    net.JUMP_CM, net.JUMP_CMS, net.JUMP_STILL = 150, 4500, 150
    local function readEnemies(now)
        local text = link.enemies()
        if text == nil or net.partnerGone then
            return
        end
        -- (A guest, just after the host's word that its world refreshed: a line still coming is from before it, a late
        -- packet's. What the host has now it says again within the second. net.dropHostLines.)
        if isClient() and now < (net.linesFrom or 0) then
            return
        end
        -- A host hears of the ones a guest's game runs (handover). Each side takes only what the other runs: a line late
        -- from before a handover pulled a copy back for a moment.
        local into = isHost() and net.guestLines or net.remoteEnemies
        for line in text:gmatch("[^\n]+") do
            local n, x, y, z, yaw, vx, vy, hp, maxhp, boss, posture = line:match(
                "^(%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
            local who = n and net.enemyNames[tonumber(n)]
            -- (Not a line from before its K, come in the same frame: it brought the dead enemy back here, and another of its
            -- class stood in for it, its hits sent for a dead one.)
            local justKilled = who and isClient() and net.killedAt and net.killedAt[who.name]
                and os.clock() - net.killedAt[who.name] < 1.5 and boss ~= "1" and boss ~= "3"
            if who and not justKilled and (isHost() and net.guestRuns[who.name] or (isClient() and not net.mine[who.name])) then
                local X, Y, Z, Yaw, Hp, MaxHp = num(x), num(y), num(z), num(yaw), num(hp), num(maxhp)
                -- Unparsable numbers or no health (MaxHp 0) would teleport or zero our copy: ignore the record.
                if X and Y and Z and Yaw and Hp and MaxHp and MaxHp > 0 then
                    -- The same table each time: puppets hold on to it and steer by the newest numbers.
                    if isClient() then
                        -- (A line from the host proves it has it: a "no" from before stops hiding it at once, not 25 s on.)
                        net.notOnHost[who.name] = nil
                    end
                    local r = into[who.name] or { Class = who.class }
                    local VX, VY = num(vx) or 0, num(vy) or 0
                    if r.X ~= nil and r.at ~= nil then
                        local sx, sy = X - r.X, Y - r.Y
                        local step2 = sx * sx + sy * sy + (Z - r.Z) ^ 2
                        if step2 > net.JUMP_CM ^ 2 and (step2 > (net.JUMP_CMS * (now - r.at)) ^ 2
                            or (r.VX ^ 2 + r.VY ^ 2 < net.JUMP_STILL ^ 2 and VX ^ 2 + VY ^ 2 < net.JUMP_STILL ^ 2)) then
                            local flat = math.sqrt(sx * sx + sy * sy)
                            r.jumpAt = now
                            r.jumpDX, r.jumpDY = flat > 1 and sx / flat or 0, flat > 1 and sy / flat or 0
                        end
                    end
                    r.X, r.Y, r.Z, r.Yaw, r.Hp, r.MaxHp = X, Y, Z, Yaw, Hp, MaxHp
                    r.VX, r.VY = VX, VY
                    -- (2, and 3 for a boss: asleep in the host's world with a guest by it. handover.asleepHere.)
                    r.Boss, r.Asleep = boss == "1" or boss == "3", boss == "2" or boss == "3"
                    r.Posture, r.at = num(posture), now
                    into[who.name] = r
                end
            end
        end
    end

    -- Guest: the host's lines so far forgotten, the ones still waiting to be read too, and none taken for LINES_AFTER_S
    -- more. Its world refreshed (handlers.R, RH): what they said was of bodies that are gone, and this world's refresh
    -- makes its own anew. Read after that word they were news again (a frame takes events before lines, and the relay
    -- keeps every line that came since the last read: a hitch here leaves seconds of them), and wrote the new bodies
    -- down to what the old ones had. A boss stopped at its floor, 383's fight starting over: the body this world's
    -- refresh made was written to 2, this player's own fight with it began, the host handed it over (RUN 1), the hold's
    -- floor went, and the next blow was its death, its pay to both and "beaten" in this save (the bench, 11-18, run207:
    -- this game stood still 5.7 s as the host's hold ended). A killing blow still waiting for its answer was the old
    -- body's as well.
    net.LINES_AFTER_S = 0.5
    function net.dropHostLines()
        link.enemies()
        net.remoteEnemies = {}
        net.lethalPending, net.ownExec, net.partnerExec, net.parrySharedAt = {}, {}, {}, {}
        if net.clearDynSpawned then net.clearDynSpawned() end
        net.dynSent, net.dynTried, net.dynPending, net.shieldSent, net.classCache, net.ownSummons = {}, {}, {}, {}, {}, {}
        for _, s in pairs(net.remoteSummons or {}) do
            if s.addr and game.visualSummons then game.visualSummons[s.addr] = nil end
            if valid(s.actor) then pcall(function() s.actor:K2_DestroyActor() end) end
        end
        net.remoteSummons = {}
        net.linesFrom = link.now() + net.LINES_AFTER_S
    end

    -- Guest: a live enemy of the host's within cm of this player, by its line of the last second. The guest's own game counts
    -- no fight with copies whose minds the host runs, so a card (game.calmForCard) goes by this too.
    function net.enemyNear(cm)
        local here, now = net.localLoc, net.frameNow or link.now()     -- (the lines' own clock: readEnemies)
        if not (isClient() and here) then
            return false
        end
        for _, r in pairs(net.remoteEnemies) do
            if r.at and now - r.at < 1 and (r.Hp or 0) > 0 and (r.X - here.X) ^ 2 + (r.Y - here.Y) ^ 2 < cm * cm then
                return true
            end
        end
        return false
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
                local actor = handover.dragonPillarFight(name) and enemyByName[name]
                if valid(actor) then
                    game.unfocus(actor:GetAddress(), actor)
                end
            end
            net.mine[name] = nil            -- (the host's lines take it from here, and pair it up again)
            return
        end
        net.mine[name] = true
        local r = net.remoteEnemies[name]
        net.remoteEnemies[name] = nil
        local actor = enemyByName[name]
        if valid(actor) then
            local addr = actor:GetAddress()
            -- (A copy kept at its own game's most, net.capped: back at the host's numbers as this game takes it over, to
            -- run the old way. Kept so, it went over with co-op's part of what it had left gone, its blows here whole.
            -- The eighth review's V6: by one narrow way, the two fights' words crossing at the start.)
            local cap = net.capped[addr]
            net.capped[addr] = nil
            if cap and cap.name == name and r and r.MaxHp and r.MaxHp > cap.most + 1 and game.setMaxHealth and game.setHealth then
                local hp = game.getHealth(actor)
                if hp then
                    game.setMaxHealth(actor, r.MaxHp)
                    game.setHealth(actor, hp * r.MaxHp / cap.most)
                end
            end
            if net.heldAlive[addr] then
                net.heldAlive[addr] = nil
                net.letGo(actor, addr, r)   -- (a boss standing at that floor: not as it stands)
            end
            if api.puppets then
                api.puppets.release(addr)   -- (its own AI back now, not when the host's lines run out)
            end
            handover.wake(name, addr)
            -- (Handed over with the host's figure hidden (down, gone, in a scene): the host's figure off
            -- its list, and its AI started now if it stands stopped. It kept the hidden figure as its target and stood
            -- by the guest ~7 s before it fought them (the gold-masked man, 11-23 18:20).)
            for _, p in ipairs(partners()) do
                if p.ghostHidden and valid(p.ghost) then
                    net.dropGhostFrom(p.ghost, { actor })
                end
            end
            game.after(0.3, function()
                if valid(actor) and net.mine[name] and not (game.isDead and game.isDead(actor))
                    and game.aiStopped and game.aiStopped(actor) and not handover.moving(actor)
                    and not (game.inCutscene and game.inCutscene()) then
                    game.startAI(actor)
                    log(name .. " handed over with its AI stopped: started at once.")
                end
            end)
        end
    end

    -- Guest: the host's figure hidden or shown again. Only the host's game took a hidden figure off the
    -- enemies' lists; the enemies this game runs (net.mine) kept going for it, standing by this player swinging at nothing.
    function net.guestOwnFight(ghost, hide)
        if isHost() or net.party or not valid(ghost) or not game.ghostInFight then
            return
        end
        if not hide then
            -- (One an enemy can go for again, as on the host; aggroParty puts the shown figure back on their lists.)
            pcall(function() ghost.BP_PBZHatredManagerComponent.CanBeHatredNow = true end)
            return
        end
        local list = {}
        for name in pairs(net.mine) do
            local a = enemyByName[name]
            if valid(a) then
                list[#list + 1] = a
            end
        end
        net.dropGhostFrom(ghost, list)
    end
    -- (Off those enemies' lists, each that went for it looking again and this player put on first: game.ghostInFight.
    -- Nobody can go for it while it's hidden; shown again, net.guestOwnFight lets them.)
    function net.dropGhostFrom(ghost, list)
        if #list == 0 or not (valid(ghost) and game.ghostInFight) then
            return
        end
        pcall(game.ghostInFight, ghost, false, list)
    end

    handlers.N = function(rest)
        local n, name, class = rest:match("^(%d+) (%S+) (%S+)$")
        if n then
            net.enemyNames[tonumber(n)] = { name = name, class = class }
        end
    end
    handlers.NQ = handlers.N        -- (the same, by the quick lane: whichever comes first)

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
            -- (Another guest's kill, of an enemy the host doesn't run: see syncEnemy. One this game told as well stays its own.)
            net.guestKillSent[name] = net.guestKillSent[name] or true
            handlers.K(name)
        end
    end

    -- The partner has just (re)started sync: it knows nothing yet. It hears again what enemies are, and what's dead.
    handlers.S = function(_, from)
        if isClient() and from then
            -- Another guest of the party started over, or someone new took that slot (the host passes it on): only what
            -- this player showed them is news to them. The host's world, its kills and what the two ran is as it was.
            log("Player " .. tostring(from) .. " started sync.")
            peerOf(from).syncAt = os.clock()
            net.lookSent = nil
            return
        end
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

    -- Guest, the host's K, the host down as it fell, its respawn held for the fight (a report on 1.7.1, three players: "if
    -- host dies during fight, they don't get items and bell (if it spawns afterwards) doesn't show up"). The host's world
    -- ran that death the "player down" way, with none of its win's steps; this world's, run with this player up, has them,
    -- and they're told to the host (flowsync.lua's DB). Down by its health (held, it says F 1), or F 2 a moment ago. A
    -- boss: { name }. Another enemy falling within DOWN_GUARD_S of such a boss and DOWN_NEAR_CM of where it fell (a guard,
    -- the win waiting for the last of them): { name, at } of that boss. Else nil.
    net.DOWN_GUARD_S, net.DOWN_NEAR_CM = 60, 6000
    function net.downWatch(name, wasBoss, quiet, actor)
        local t = net.target
        if quiet or not (api.flowsync and api.flowsync.watchDownFlow) then
            return nil
        end
        if not ((t and t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0)
            or (net.hostDownAt and os.clock() - net.hostDownAt < 15)) then
            return nil
        end
        if wasBoss then
            return { name = name }
        end
        local last = net.downBossFell
        if last and os.clock() - last.at < net.DOWN_GUARD_S and valid(actor) then
            local ok, l = pcall(function() return actor:K2_GetActorLocation() end)
            if ok and l and (l.X - last.where.X) ^ 2 + (l.Y - last.where.Y) ^ 2 <= net.DOWN_NEAR_CM ^ 2 then
                return { name = last.name, at = last.where }
            end
        end
        return nil
    end

    -- Guest: killForReal, the death run here. With down (downWatch's), what it adds from then on is watched for the host:
    -- only once it ran here (one killed quietly ran no win, and what came meanwhile was this player's own play).
    function net.killWatched(actor, down)
        local flow = api.flowsync
        local before = down and flow.readFlow()
        local where = down and (down.at or select(2, pcall(function()
            local l = actor:K2_GetActorLocation()
            return { X = l.X, Y = l.Y }
        end)))
        local ran = game.killForReal(actor)
        if ran and before then
            flow.watchDownFlow(down.name, before)
            if not down.at and type(where) == "table" then
                net.downBossFell = { name = down.name, at = os.clock(), where = where }     -- (a guard of its fight: downWatch)
            end
        end
        return ran
    end

    -- Guest: a copy's death by the host's word (handlers.K), the game's own.
    function net.dieHere(name, actor, down, byGuest)
        -- The game's own death, at level 0 so it pays nothing here: the quiet kill skipped what listens for
        -- deaths, and a quest waiting for the monsters to be dealt with (Fierce Axe) never moved, not even after
        -- a reload.
        if net.killWatched(actor, down) then
            log("Host says " .. name .. " died; it dies here too.")
            -- (Nothing of it is owed: with the host down, or up within its quiet after, no share of it
            -- comes, and its copy's own pay taken back left this player nothing for the kill. When the host
            -- was last seen down goes with the copy's pay: pbz.lua's watchCurrency. The review of 11-16.)
            -- (This kill's own roll alone: a boss's in the same pay is owed, its share comes once the host
            -- is up. The third review.)
            -- (The host at 0 now counts: seen down only after a second, a kill in that second was taken
            -- back with no share to come.)
            local downAt = net.zeroSince and os.clock() or net.downSeenAt
            if game.copyPay and not byGuest and downAt
                and os.clock() - downAt < game.dustWatch.AFTER_DOWN_S then
                game.copyPay.hostDownAt = downAt
                game.copyPay.keep = (game.copyPay.keep or 0) + (game.copyPay.last or 0)
            end
        else
            log("Host says " .. name .. " died; its death was refused here: tried again, then dissolved.")
        end
    end

    -- 417: its death to see first (puppets.lua's deathShow has started it, or left an execution of this player's own
    -- to run): the kill comes when that is over, the copy found again by its address and its actor's name. Its bar
    -- off and its floor kept meanwhile; told dead again meanwhile, nothing more is done. One not found any more is
    -- ended when it is next met, as one the host called dead while it wasn't loaded.
    net.dying = {}          -- a copy's address -> { name, till }: its death is being shown
    net.DYING_STEP_S = 0.03
    function net.isDying(addr)
        local d = net.dying[addr]
        return d ~= nil and os.clock() < d.till
    end
    function net.dieLater(name, actor, wait, what, down, byGuest, show)
        local addr = actor:GetAddress()
        local body = tostring(select(2, pcall(function() return actor:GetFName():ToString() end)))
        local began = os.clock()
        net.dying[addr] = { name = name, till = began + wait + 0.5 }
        game.hideHealthBar(actor)
        if game.setMinHealth then
            game.setMinHealth(actor, HELD_HP)       -- (its floor through the show: a blow meanwhile doesn't end it)
        end
        log(string.format("Host says %s died; its %s is shown here first (%.1f s at most).", name, what or "death", wait))
        -- (Every few frames till it is over: puppets.lua's showOn keeps the fall on it, and says when an execution
        -- has ended. The copy by its address and its actor's name each time: nothing of the game's is kept.)
        local function step()
            local found = nil
            local list, addrs = game.listEnemies()
            for i, at in ipairs(addrs or {}) do
                local a = list[i]
                if at == addr and valid(a)
                    and tostring(select(2, pcall(function() return a:GetFName():ToString() end))) == body then
                    found = a
                    break
                end
            end
            if not found then
                net.dying[addr] = nil
                net.pendingDeaths[name] = true
                return
            end
            if game.isDead and game.isDead(found) then
                net.dying[addr] = nil
                return
            end
            local over = os.clock() - began >= wait
            if not over and show and api.puppets and api.puppets.showOn then
                local ok, on = pcall(api.puppets.showOn, found, what, show, os.clock() - began)
                over = not ok or on == false
            end
            if over then
                net.dying[addr] = nil
                net.dieHere(name, found, down, byGuest)
            else
                game.after(net.DYING_STEP_S, step)
            end
        end
        game.after(net.DYING_STEP_S, step)
    end

    -- quiet: a death from before (BEATEN), not the end of a fight going on.
    handlers.K = function(name, _, quiet)
        local actor = enemyByName[name]
        net.lethalPending[name] = nil
        if isClient() then
            -- (Told again, the host's re-tell after a gap: one already handled here, not standing alive, costs nothing. Each
            -- went through the searches below, and 40 at once held the guest's frame for 100-160 ms. One not heard before,
            -- or back alive since, or in a fight again, goes the whole way.)
            if net.hostKilled[name] and not net.hostBosses[name] and not net.broughtBack[name]
                and not (valid(actor) and not (game.isDead and game.isDead(actor))) then
                return
            end
            net.hostKilled[name] = true
            net.killedAt = net.killedAt or {}
            net.killedAt[name] = os.clock()
            net.remoteEnemies[name] = nil
            net.mine[name] = nil
            -- (The host's death settles a kill of this player's still to tell: a hit left here kept the dead body paired
            -- under its id, and a boss up again on the host never came back here.)
            net.hitHere[name] = nil
            -- (Another guest's kill, told by GK: its share comes from them, not the host.)
            local byGuest = net.guestKillSent and net.guestKillSent[name]
            if net.guestKillSent then
                net.guestKillSent[name] = nil
            end
            if not valid(actor) then
                actor = stickyEnemy(name)
            end
            if not valid(actor) then
                actor = bring.own(name)
            end
            local fought = net.hostBosses[name] or net.partnerBosses[name] or net.pendingBosses[name]
            local wasBoss = fought or (valid(actor) and game.isBoss and game.isBoss(actor))
            -- (A fight of this player's own the host never joined, by the bars told: its fall began no scene of the
            -- host's. One both were in, this player's bar up first, is the host's fight too. In a party only the host's
            -- bar says so: another guest's, up in the same moment as this player's, is no joining. flowsync.lua's
            -- holdStarts.)
            net.ownFell = net.ownFell or {}
            net.ownFell[name] = (net.ownAnnounced or {})[name]
                and not (net.partnerBosses[name] and (not net.party or net.fightOf[name] == 1)) or nil
            net.hostBosses[name] = nil
            if wasBoss and not quiet then
                net.bossFell = net.bossFell or {}
                net.bossFell[name] = net.frameNow or link.now()     -- (fell in a fight: one up again on the host comes back, see bring.missing; its clock)
                -- (And for the sweep as the host's fight ends, see handlers.F: its K comes first and takes the name off the
                -- fights shown here, so after a host's win nothing was put down.)
                net.endedInFight = net.endedInFight or {}
                net.endedInFight[name] = os.clock()
            end
            local down = net.downWatch(name, wasBoss, quiet, actor)
            -- (A kill told while a finishing move is under way on it, this player's own or a partner's (net.ownExec,
            -- net.partnerExec, pull request 20). That pull request put the kill off till the move's end, a second and
            -- more: but the host's line of the copy is gone at this word, so its floor was let go, the move's next blow
            -- ended it by the game's own death, and both players were paid for it twice (the bench, 11-24, run268: one
            -- elite, 327 shared to the guest and 321 back to the host). 417's show waits such a move out with the copy
            -- held and its floor kept, net.dieLater below, and ends it at no pay. moveOn: one a move was flagged on
            -- but with no hold of the game's on it now gets no fall of its kind after: the move was its death to see.
            -- Its lock, pbz.lua's execLock, comes off with the kill itself, not before the show is asked.)
            local moveOn = (net.partnerExec and net.partnerExec[name] ~= nil) or (net.ownExec and net.ownExec[name] ~= nil) or false
            if valid(actor) then
                if api.puppets then
                    api.puppets.drop(actor)
                end
                -- (Dead by the game's own word, not only at 0 health: a copy written to 0 never had its death run.)
                local gameDead = select(2, pcall(function() return actor:IsDead() end)) == true
                -- (Or this game's own kill, told by GK: its death here is the game's own, by this player's blow. A boss
                -- is a moment into its fall before the game calls it dead, and the host's word back found it "not dead
                -- yet": its death was run a second time, and its pay, this player's earnings, taken back as a copy's own
                -- like the host's copy's. Nobody had the boss's dust for a guest's kill: the bench of 11-16, three
                -- copies, 6600 taken back on the killer's PC and on the host's.)
                if game.isDead and game.isDead(actor)
                    and (byGuest == "own" or not (fought and not quiet and not gameDead and game.killForReal)) then
                    -- (Dead here first, by its own death: one this game ran (handover), whose death cut short looked wrong.)
                    log("Host says " .. name .. " died; it's dead here already.")
                elseif fought and not quiet and game.killForReal then
                    -- The boss of a fight both are in: the whole death here too, so this world's story goes on with the
                    -- host's, its scene after the fight first (a quiet kill skipped it, and the next phase came unseen).
                    if net.killWatched(actor, down) then
                        log("Host says " .. name .. " died; its death runs here too.")
                    elseif game.kill then
                        -- (Refused here (a phase or floor of this world's own): the host's word stands, the quiet death.)
                        game.kill(actor)
                        log("Host says " .. name .. " died; its death was refused here, killed it quietly.")
                    end
                elseif not wasBoss and not quiet and game.killForReal then
                    -- (417: its death to see first, where there is one to show: net.dieLater.)
                    if not net.isDying(actor:GetAddress()) then
                        local wait, what, show = 0, nil, nil
                        if api.puppets and api.puppets.deathShow then
                            local ok, w, k, m = pcall(api.puppets.deathShow, name, actor, moveOn)
                            if ok and type(w) == "number" then
                                wait, what, show = w, k, m
                            end
                        end
                        if wait > 0 then
                            net.dieLater(name, actor, wait, what, down, byGuest, show)
                        else
                            net.dieHere(name, actor, down, byGuest)
                        end
                    end
                elseif game.kill then
                    game.kill(actor)
                    log("Host says " .. name .. " died; killed it here.")
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

    -- A boss's flinch at a partner's hit, played on the boss itself only now and then. (Every one was: the copy's flinch,
    -- forced with every montage stopped, cut the boss's attack with no hit and held it 0.3-2.5 s where it can't start a move;
    -- with two players hitting it, it never fought back. Nexus reports on 1.6.6: "it gets continuously hit and can't fight
    -- back".) A posture break plays, once: emptied, the hit that took the bar from full to empty. (Every hit on an empty bar
    -- did, even in a move: read after the partner's own write, and a bar a partner empties stays empty till its refill 6 s
    -- on. In the sim a guest swinging every 0.75 s at it kept the boss from any move for those 6 s. On the bench, 11-09, the
    -- elite swordsman's bar read 4 there, not 0, so it was rarer than it looks.) In a move of its own its own poise decides:
    -- the partner's figure's swing reached it here already; and a reaction the game set itself plays out (forced over it, the
    -- game's own break was cut short). Between moves, one in BOSS_REACT_S x CoopBossPoise/100. (Fields, not locals: this
    -- function is at Lua's 200.)
    net.BOSS_REACT_S = 1.5
    net.bossReactAt = {}
    net.bossBrokeAt = {}
    function net.bossMayReact(name, actor, emptied)
        -- (An armoured boss takes no flinch of a partner's, scaling.lua's CoopBossArmor: its own would be let go anyway. A
        -- break still plays.)
        if not emptied and api.scaling and api.scaling.armoured and api.scaling.armoured(actor) then
            return false
        end
        local now = os.clock()
        local wait = net.BOSS_REACT_S * ((api.scaling and api.scaling.bossPoise) or 2)
        if emptied then
            if now - (net.bossBrokeAt[name] or -1e9) < (game.POSTURE_BREAK_S or 6) then
                return false
            end
            net.bossBrokeAt[name] = now
            net.bossReactAt[name] = now + wait
            return true
        end
        -- (Nor a flinch in the 6 s after a partner's break: its bar waits empty for its refill then, in no fill and no
        -- recovery of the game's, and a flinch 3 s on came through.)
        if now - (net.bossBrokeAt[name] or -1e9) < (game.POSTURE_BREAK_S or 6) then
            return false
        end
        if api.puppets and api.puppets.inMove(name) then
            return false
        end
        local state = game.hitStateOf and game.hitStateOf(actor)
        if state and state ~= "None" then
            return false
        end
        if now < (net.bossReactAt[name] or 0) then
            return false
        end
        net.bossReactAt[name] = now + wait
        return true
    end

    -- from: the slot of the guest who hit it, with more than two players, or nil. Where they are is peerOf(from).target, which
    -- with two players is net.target: anything that asks where "the guest" is must go by that, not by net.target, which in a
    -- host's party is only its first guest here.
    handlers.D = function(rest, from)
        local name, amount, posture, lethal = rest:match("^(%S+) (%S+)%s*(%S*)%s*(%S*)")
        if name and net.ownExec and net.ownExec[name] then
            local a = enemyByName[name]
            local isBoss = valid(a) and ((game.isBoss and game.isBoss(a)) or (game.bossTwin and game.bossTwin(a)))
            if not isBoss then
                return
            end
        end
        -- Checked before anything else: a real number in range (the lethal flag below can't smuggle in more).
        amount = num(amount)
        if amount == nil or amount < 0 or amount > MAX_EVENT_DAMAGE then
            return
        end
        -- (Told in a gap of that guest's link in which this world refreshed: struck at a body that's gone. net.gapOld.)
        if net.gapOld(from, "a blow on " .. tostring(name)) then
            return
        end
        posture = num(posture)
        posture = posture and math.max(0, math.min(posture, MAX_EVENT_DAMAGE)) or 0
        local told = amount
        -- (X: a killing blow that is the sender's own finishing move, the game's, on its copy of a boss: reportHit. A
        -- killing blow in all else.)
        local finisher = lethal == "X"
        if finisher then
            lethal = "L"
        end
        if lethal == "L" and net.lateKill() then
            log("Partner's killing blow on " .. tostring(name) .. " came as this world refreshed: of the one that's gone, a plain blow here.")
            lethal, finisher = "-", false
        end
        -- (Told in a gap of that guest's link, net.gapKill: a plain blow. It is still answered below with what this
        -- one has (LR), as any killing blow not taken: the guest's game stops telling it again, and its copy takes
        -- that. With no answer it was told again past the gap, and taken where the gap's blows had left the boss low.)
        local gapTold = lethal == "L" and not finisher and net.gapKill(from)
        if gapTold then
            log("Partner's killing blow on " .. tostring(name) .. " was told in a gap of theirs: a plain blow here.")
        elseif lethal == "L" then
            amount = math.huge      -- the client's killing blow (its copy can't show the full damage)
            log("Partner's " .. (finisher and "finishing move" or "killing blow") .. " on " .. tostring(name)
                .. (valid(enemyByName[name]) and "." or ", which isn't loaded here."))
        end
        -- The reaction the hit made on the sender's copy, played on the enemy itself (puppets.react). Only a hit state.
        local rpath, rpos, rtag = rest:match("^%S+ %S+ %S+ %S+ (%S+) (%S+) (%S+)$")
        rpos = num(rpos)
        if not (rtag and rtag:match("^CharacterState%.[%w%.]+$") and rtag:lower():find("hitreact", 1, true)
            and rpos and rpos >= 0 and rpos < 600 and #rpath <= 256) then
            rtag = nil
        end
        local function react(actor)
            -- (Once a hit: the figure's own token blow can have put the enemy in this very state, and playing it again
            -- restarted that reaction, a jump, and set the hit state twice. Another state, a break or a knockdown, plays.)
            if rtag and api.puppets and not (game.isDead and game.isDead(actor))
                and not (game.hitStateOf and game.hitStateOf(actor) == rtag) then
                api.puppets.react(name, actor, rpath, rpos, rtag)
            end
        end
        if isClient() and name and net.mine[name] then
            -- The host's hit on one this game runs (handover): it lands here, where the enemy lives. A killing blow is its
            -- whole death here, paying this player, and that dust reaches the host as any of this player's does.
            local actor = enemyByName[name]
            if valid(actor) and game.applyDamage and net.target and gap3d(actor:K2_GetActorLocation(), net.target) <= OWN_HIT_CM then
                local before = handover.dragonPillarFight(name) and game.getHealth(actor)
                game.applyDamage(actor, amount, posture, true)
                react(actor)
                local left = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                    addr = actor:GetAddress() }
                if before and left.hp then
                    game.partnerHit(left.addr, 1, before - left.hp)
                end
                seen[name] = left           -- (a reported hit: its turn mustn't weigh it again, nor undo it)
                if round.seen and round.seen[name] then
                    round.seen[name] = left
                end
            end
        end
        -- (One the guest's game runs takes no hits here: its lines say what it has left.)
        if isHost() and name and not net.guestRuns[name] then
            local actor = enemyByName[name]
            -- (A killing blow is looked for further: one on an enemy just past this round's list, or a little further off than
            -- a hit, was dropped without a word, and the guest's copy stood at 1 health for good, still taking hits.)
            if not valid(actor) and lethal == "L" and game.listEnemies then
                for _, a in pairs(game.listEnemies() or {}) do
                    if valid(a) and enemyName(a, a:GetAddress()) == name then
                        actor = a
                        break
                    end
                end
            end
            local hitter = peerOf(from).target
            local killed = false
            -- (One kept at its game's most, scaling.lua's capped: a copy that ran ahead of it is on its floor with more
            -- left here than f times this blow. A blow then, not its death, and LR says what it has.)
            if lethal == "L" and valid(actor) and api.scaling and api.scaling.capped then
                local f = api.scaling.capped(actor, actor:GetAddress())
                local left = f and game.getHealth(actor)
                if left and left > told * f + 1 then
                    amount = told
                end
            end
            if valid(actor) and game.applyDamage and hitter
                and gap3d(actor:K2_GetActorLocation(), hitter) <= OWN_HIT_CM * 2 then
                local wasAlive = not (game.isDead and game.isDead(actor))
                local boss = net.partnerBosses[name] or (game.isBoss and game.isBoss(actor))
                local before, most = game.getHealth(actor)
                -- (A killing blow on a boss with more than half its health left here, by a blow that took less than
                -- half of what it has: of a body that's gone. The sender's copy stood at its floor, and this one is
                -- whole again: by this world's refresh, read past net.lateKill's half second; by a sit's reset
                -- (net.sitBossesToFull); by the game's own, a boss that lost its target (the bench, run223: 2 back to
                -- 27680 with no refresh at all), once that has it over half again. By the blow, not by a clock from
                -- the refresh: a guest whose link went quiet for longer than any window kept striking its copy at 2,
                -- the relay sent those killing blows as the link came back, and the whole boss died (REVIEW-10). A
                -- plain blow, and LR says what this one has. One that took it whole is still its end. This judges
                -- the one blow as it's read: the plain blows of a quiet link, read before it, can have taken the
                -- boss under half, and a reset is under half in its first seconds. Those are net.gapKill's, above.)
                if lethal == "L" and not gapTold and boss and before and most and before > most / 2 and told < before / 2 then
                    log(string.format("Partner's killing blow on %s isn't one here: it has %.0f of %.0f. A plain blow.", name, before, most))
                    amount, finisher = told, false
                end
                -- (A boss weighs a partner's blow by the game's own rules for one: no posture in its break and fill, as it
                -- recovers, or while it turns blows aside, and no reaction of theirs on it then. See game.partnerRefuses.)
                local bossLike = boss or (game.bossTwin and game.bossTwin(actor)) or false
                local refused = bossLike and game.partnerRefuses and game.partnerRefuses(actor, actor:GetAddress())
                -- (Not a break the sender's copy has already had: its game broke it at once, past taking back, and its bar,
                -- kept with this one's, came there by blows this world took. Turned aside, the guest saw a break the host's
                -- boss never had. Its break and fill, or its recovery, still refuse one.)
                if refused == "aside" and rtag ~= nil and rtag:find("State%.Break") then
                    refused = nil
                end
                if refused then
                    posture = 0
                end
                -- (A partner's own finishing move on a boss this game holds at its last point: taken, 395. The floor
                -- off for this blow and the game's own kill then, the whole death, as by this player's own finishing
                -- move: the bench, 11-18, run211, the Axe chief's flow steps, flags, axe and pay as at his real end,
                -- run188. Only where that is its end: a floor of the last point (1), the boss low (it may stand over
                -- that floor still: the game's mark for a finishing move comes up there), no sequence playing here,
                -- and no other phase of it to come (game.phaseAfter). The game's kill takes whatever holds Health_Min
                -- once that's 0 (run211: his lock was still on him), so at a phase's floor, or one held for a scene, it
                -- would be 193 again. The tenth review. The floor back if the game still won't let it die.)
                local floor0 = nil
                if finisher and boss and game.healthFloor and game.setMinHealth and before then
                    local floor = game.healthFloor(actor)
                    if floor >= 1 then
                        local why = (floor > HELD_HP + 0.5 and "the floor there is a phase's")
                            or (not (most and before <= math.max(floor + 1.5, most * net.EXEC_LOW)) and "it isn't low there")
                            or (game.sequenceOn and game.sequenceOn() and "a scene plays there")
                            or (game.phaseAfter and game.phaseAfter(name) and "another phase of it is to come")
                        if why then
                            log("A finishing move on " .. name .. " isn't its end here: " .. why .. ".")
                        else
                            floor0 = floor
                            game.setMinHealth(actor, 0)
                        end
                    end
                end
                if lethal == "L" and net.partnerExec and net.partnerExec[name] then
                    net.partnerExec[name] = nil
                    if game.execLock then
                        game.execLock(actor, false)
                    end
                end
                local real = game.applyDamage(actor, amount, posture, true)
                if floor0 and not real and not (game.isDead and game.isDead(actor)) then
                    game.setMinHealth(actor, floor0)
                end
                -- (What it took, for who the enemy goes for: a floor or a kill takes less than was sent.)
                game.partnerHit(actor:GetAddress(), from, (before or 0) - (game.getHealth(actor) or before or 0))
                -- (A break: the one this hit made on the sender's copy, its posture break's tag, State.Break, not the poise
                -- levels, Hitreact.Break.LvN. A bar this hit took to empty here with no break there played nothing, yet
                -- it used up the break's once, and the copy's own break a moment on was refused: the guest saw a break the
                -- host's boss never had.)
                local barAfter = game.getPosture and game.getPosture(actor)
                local emptied = not refused and rtag ~= nil and rtag:find("State%.Break") ~= nil
                if not bossLike or (not refused and net.bossMayReact(name, actor, emptied)) then
                    react(actor)
                    -- (A partner's break played here: the bar emptied as the sender's copy's, to fill again as after a break,
                    -- refillEmptied. Left a few points up (the game holds a broken bar a little above 0, the elite
                    -- swordsman's at 4 on the bench), nothing filled it: it stood broken for good, broken again at every
                    -- break of the copy's. One already at 0 is filled the same, unless a refill waits already.)
                    if emptied and barAfter and game.setPosture then
                        if barAfter > 0 then
                            game.setPosture(actor, 0)
                            game.postureEmptied[actor:GetAddress()] = os.clock()
                        elseif not game.postureEmptied[actor:GetAddress()] then
                            game.postureEmptied[actor:GetAddress()] = os.clock()
                        end
                    end
                end
                if wasAlive and (real or (game.isDead and game.isDead(actor))) then
                    -- (A boss of the fight this player went down in, its respawn held: what it pays here is owed till
                    -- they're up, its win's steps from a guest's world. See shareEnemy. The bench, 11-12: the game had
                    -- taken the gold-masked man's bar down as the host died, he was no boss here then, and nothing of
                    -- his was owed: the guest's word of his win was turned down.)
                    local owed = net.deadSince ~= nil and game.downBoss and game.downBoss(name, boss)
                    if real and (boss or owed) and game.rollLoot then
                        -- The game ran the whole death and paid this player, as for their own blow. A boss's items are
                        -- the client's too: by the share of what the game gave here (T), as any kill's since 1.6.7. Told
                        -- by name as well (I), as before there were shares, the guest had each twice. Only one owed,
                        -- this player down, is still told: its pay is kept here till they're up.
                        local bossDust, items = game.rollLoot(actor)
                        local paid = {}
                        if owed then
                            sendItems(name, items, paid)
                        end
                        if #paid > 0 then
                            log("Boss items for your partner too: " .. table.concat(paid, ", ") .. ".")
                        end
                        if owed then
                            game.oweBoss(name, bossDust, items)
                        end
                    elseif not real and game.rollLoot then
                        -- (A boss's: everyone's, as by its real death.)
                        local bossDust, items = payKillLoot(name, actor, nil, not (boss or owed) and from or nil)
                        if owed then
                            game.oweBoss(name, bossDust, items)
                        end
                    end
                    -- At once, not at the enemy's next turn: the partner is looking at a copy held at 1 health.
                    net.deadSent[name] = true
                    net.deadBodies[actor:GetAddress()] = tostring(select(2, pcall(function()
                        return actor:GetFName():ToString() end)))
                    net.bossPaid = net.bossPaid or {}
                    net.bossPaid[actor:GetAddress()] = net.deadBodies[actor:GetAddress()]     -- (its items: paid here)   -- (by the body too, as shareEnemy marks it: else a new enemy
                                                                -- under the id cleared the name, the old body told it again,
                                                                -- and a boss's items went out twice)
                    sendEvent("K", name)
                    killed = true
                    if game.markBeaten then
                        -- (Its turn below won't see this death: deadSent is up already. A boss the guest finished came
                        -- back on the host's next load.)
                        game.markBeaten(name)
                    end
                    if boss then
                        endBossFight(name, actor)
                        net.bossFellAt = os.clock()         -- (its win's flow goes out whole: flowsync.lua's hostTick)
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
            -- A killing blow not taken here: said so (LR), with what it has left, so the guest's copy isn't held at 1 for good.
            -- Dead here already (its K came before, or was lost): told again.
            if lethal == "L" and not killed then
                if net.deadSent[name] or (valid(actor) and game.isDead and game.isDead(actor)) then
                    sendEvent("K", name)
                elseif valid(actor) then
                    -- (Not taken at a floor of its game's own: noted. For a host who's down, net.finisherWaits; for one
                    -- who's up, net.finisherSaid.)
                    if game.atOwnFloor and game.atOwnFloor(actor) then
                        net.floorRefused[name] = os.clock()
                    end
                    -- (One kept at its game's most: co-op's part of this blow given back first, as before a line of it
                    -- goes (scaling.look). Read before that, the copy was put that part of a blow under the host's
                    -- boss, and its next floor came that much early. The eighth review.)
                    if api.scaling and api.scaling.capped and api.scaling.capped(actor, actor:GetAddress()) then
                        api.scaling.look(actor)
                    end
                    local hp = game.getHealth(actor)
                    if hp then
                        -- (Co-op's number of it, as its line says: one kept at its game's most stands for f times it.)
                        hp = hp * (api.scaling and api.scaling.capped and api.scaling.capped(actor, actor:GetAddress()) or 1)
                        -- (To that guest alone: another guest's own killing blow on it, still on its way, was dropped.)
                        if from then
                            sendTo(from, "LR", name, string.format("%.1f", hp))
                        else
                            sendEvent("LR", name, string.format("%.1f", hp))
                        end
                    end
                end
            end
        end
    end

    -- Guest: the host didn't take this killing blow (LR <name> <health there>): the copy takes the host's health, and is
    -- reported again if hit to its floor once more.
    handlers.LR = function(rest, from)
        local name, hp = (rest or ""):match("^(%S+) (%S+)$")
        hp = num(hp)
        if from ~= nil or isHost() or not name or not hp then
            return
        end
        -- (Only for a killing blow that waits for its answer. One told just before the host's world refreshed gets its
        -- LR after it, and that wrote the body this world's refresh had made, let go already, down to 2: 394's free
        -- kill by another way. The tenth review.)
        local waited = net.lethalPending[name]
        net.lethalPending[name] = nil
        local actor = enemyByName[name]
        -- (And only on a copy still held. One let go since the blow went, the host's lines of it run out with no word
        -- (the host gone off, its boss at a floor of its game's own), stands whole and is this game's own (net.letGo):
        -- the answer put it at 2 with no floor, and the next blow was its death here alone, told to a party's other
        -- guests. A blow is told only of a held copy, and held it stays while the host's lines come: no answer that's
        -- needed is dropped. The tenth review's checks.)
        if waited and valid(actor) and net.heldAlive[actor:GetAddress()] ~= nil and game.setHealth
            and not (game.isDead and game.isDead(actor)) then
            -- (A copy kept at its own game's most: the host's share of that.)
            local cap, r = net.capped[actor:GetAddress()], net.remoteEnemies[name]
            if cap and cap.name == name and r and r.MaxHp and r.MaxHp > cap.most + 1 then
                hp = hp * cap.most / r.MaxHp
            end
            game.setHealth(actor, math.max(HELD_HP + 1, hp))
            if seen[name] then
                seen[name].hp = math.max(HELD_HP + 1, hp)
            end
            log("The host didn't take the killing blow on " .. name .. ": it has " .. string.format("%.0f", hp) .. " left there.")
        end
    end

    ------------------------------------------------------------------ items

    -- What the game gave the partner. Played with nobody in the world (a map loading) it waits. So does what's shared by word.
    local giftsWaiting = {}
    local dustWaiting = 0

    handlers.I = function(rest, from)
        -- (A ground pickup's word ends in what it held and how many: reportPickup. An older one's had neither.)
        local name, itemId, kind, held, n = rest:match("^(%S+)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)")
        -- (Every way on gets the same limits: the item went to the backpack unchecked when this player was there.)
        if name and game.takeRemotePickup and #name <= MAX_CHEST_NAME and #itemId <= MAX_ITEM_NAME and #kind <= 16
            and #held <= MAX_ITEM_NAME then
            local _, pawn = getPlayer1()
            kind = (kind ~= "" and kind ~= "-") and kind or nil
            n = num(n)
            n = (n and n >= 1 and n <= MAX_GIFT and n == math.floor(n)) and n or nil
            if valid(pawn) or name:sub(1, 5) ~= "loot:" then
                local t = peerOf(from).target          -- (the map it lies on: theirs)
                game.takeRemotePickup(name, itemId, pawn, kind, t and t.Map, net.party and (from or 1) or nil,
                    held ~= "" and held or nil, n)
            else
                giftsWaiting[#giftsWaiting + 1] = { id = itemId, count = 1, kind = kind, loot = true }
            end
        end
    end

    handlers.O = function(name, from)
        if name and #name <= MAX_CHEST_NAME and game.partnerOpened then
            game.partnerOpened(name, net.party and (from or 1) or nil)
        end
    end

    -- What a pile or chest the partner searched raised in their world, its own flow's flags (game.successTags): raised here
    -- too when it's calm (flowsync.lua), as a search of our copy would have. Its things come by T and our copy goes with O,
    -- but these never came, and a quest counting them never moved on here: Yuer's three herbs, two found by the partner,
    -- and she wouldn't take them (a player report on 1.7.1). Either way, the host's search or a guest's. OF <name> <flag> ...
    handlers.OF = function(rest)
        local name, flags = (rest or ""):match("^(%S+) (.+)$")
        if not (name and #name <= MAX_CHEST_NAME and #flags <= 1600 and api.flowsync and api.flowsync.raise) then
            return
        end
        local list = {}
        for flag in flags:gmatch("%S+") do
            if #flag <= 200 and #list < 8 then
                list[#list + 1] = flag
            end
        end
        api.flowsync.raise(list, name)
    end

    handlers.T = function(rest, from)
        local id, count, kind = rest:match("^(%S+) (%d+) (%S+)$")
        count = num(count)
        if id and #id <= MAX_ITEM_NAME and #kind <= 16 and count and count >= 1 and count <= MAX_GIFT then
            giftsWaiting[#giftsWaiting + 1] = { id = id, count = count, kind = kind ~= "-" and kind or nil, from = from,
                at = os.clock() }
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
        -- (Story sync off (FollowHostStory = Off): this player's game is its own, the things it hasn't found too. The bag
        -- still filled up from the host's on joining.)
        if waiting and api.story and api.story.follow == false then
            net.bagWaiting = nil
            log("Story sync is off: nothing taken from the host's bag.")
            waiting = nil
        end
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

    -- (What came shows on the right as the game shows a find, its own notice (the user, 11-09): game.grantLoot. Not a word
    -- of ours: the user didn't want "your partner found something" on screen.)
    -- A partner's find waits a moment before it's given here: this world's own game can give the same thing for the same
    -- event a little after. (A kill's reward: the host's game gives it at the death, the guest's copy dies at the host's K and
    -- its game gives it too. The share came first and receiveGift drops one only when this world gave first: the guest kept
    -- both, a Killing Aura Amber say; a report on 1.6.9.) Given here meanwhile, receiveGift drops the share: one each. Longer
    -- while a scene plays (a boss's death), never past SAME_GIFT_S of pbz.lua's that its check goes by. (Its numbers inside
    -- it: this function is at Lua's 200 locals.)
    local function takeGifts(pawn)
        local GIFT_HOLD_S, GIFT_HOLD_MAX_S = 3, 12
        local now, kept = os.clock(), {}
        local scene = game.inCutscene and game.inCutscene()
        local left = {}             -- (shares of each thing still to come after this one: receiveGift's more)
        for _, gift in ipairs(giftsWaiting) do
            if not gift.loot then
                left[gift.id] = (left[gift.id] or 0) + 1
            end
        end
        for _, gift in ipairs(giftsWaiting) do
            local age = now - (gift.at or now - GIFT_HOLD_MAX_S)
            if gift.loot then
                game.grantLoot(pawn, gift.id, gift.kind)
            else
                left[gift.id] = left[gift.id] - 1
                if age < GIFT_HOLD_S or (scene and age < GIFT_HOLD_MAX_S) then
                    kept[#kept + 1] = gift
                else
                    game.receiveGift(pawn, gift.id, gift.count, gift.kind, net.party and (gift.from or 1) or nil,
                        left[gift.id] > 0, gift.at)
                end
            end
        end
        giftsWaiting = kept
        if dustWaiting > 0 and game.addCurrency then
            game.addCurrency(pawn, dustWaiting)
            dustWaiting = 0
        end
    end

    local function reportChest(name, flags)
        log("Opened " .. name .. ": telling the other player.")
        sendEvent("O", name)
        if flags and #flags > 0 then
            sendEvent("OF", name, table.concat(flags, " "))     -- (what its flow raised: handlers.OF)
        end
    end

    -- The host's world decides (FollowHostStory): a chest the host opened before, alone, is opened for a guest too, and pays
    -- them what it holds there, so both have the same things. The host names the open chests it has loaded (OC).
    local function offerChest(name)
        sendEvent("OC", name)
    end

    handlers.OC = function(name, from)
        if from ~= nil then
            return          -- (the host's word only: another guest's, passed on by the relay, is no host's)
        end
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
            and math.abs(x) < 1e8 and math.abs(y) < 1e8 and math.abs(z) < 1e8 then
            game.stoneKicked(name, { X = x, Y = y, Z = z }, { Pitch = pitch, Yaw = yaw, Roll = roll })
            log("The other player kicked " .. name .. " away: here too.")
        end
    end

    -- This player picked a Memory Flower (pbz.lua's game.hookFlowers): named to the others with its petal and quest flags,
    -- for their copy to go once they have the petal and their quest to count it. The petal itself goes by T, as any find
    -- does. MF <flower> <petal> [<flag> ...]
    function net.reportFlower(name, petal, flags)
        log("Picked the Memory Flower " .. name .. " (" .. petal .. "): telling the other players.")
        sendEvent("MF", name, petal, table.concat(flags, " "))
    end

    -- Another player picked a Memory Flower: our copy goes too, the game's way, once its petal is in our bag
    -- (game.flowerTaken: looked for in the slow tick, after the quiet of a load), and the flags the game raises for it as its
    -- card closes are raised here when it's calm (flowsync.lua), as a pick here would: a quest counting the flowers
    -- ("Resonant Strings: Collect Memory Flowers of Inanis and the Chord") counts theirs. Either way, the host's pick or a
    -- guest's: the host takes no story flags from guests, and the host's own reach guests by FLOW as well.
    handlers.MF = function(rest)
        local name, petal, flags = (rest or ""):match("^(%S+) (%S+)%s*(.*)$")
        if not (name and #name <= MAX_CHEST_NAME and #petal <= MAX_ITEM_NAME and #flags <= 1600 and game.flowerTaken) then
            return
        end
        log("The other player picked the Memory Flower " .. name .. " (" .. petal .. ").")
        game.flowerTaken(name, petal ~= "-" and petal or nil)
        net.flowersSoon = true      -- (looked at the next slow tick, not after an old word's 30 s: as net.chestsSoon)
        local list = {}
        for flag in flags:gmatch("%S+") do
            if #flag <= 200 and #list < 8 then
                list[#list + 1] = flag
            end
        end
        if #list > 0 and api.flowsync and api.flowsync.raise then
            api.flowsync.raise(list, name)
        end
    end

    -- Host: a guest started a drink from the gourd. Its enemies near them look their way for a while (game.steerTarget). (A
    -- guest hearing another guest's, passed on, does nothing: only the host's enemies choose.)
    handlers.HEAL = function(_, from)
        if isHost() and game.playerHealed and not net.pvp then
            game.playerHealed(from or 2)
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
        -- (Only that it's gone: the item itself goes by T, like everything the game gives. What it held and how many come
        -- too, for a partner whose copy wasn't loaded to wait for that share all the same: game.takeRemotePickup.)
        sendEvent("I", name, "?", "-", itemId or "-", game.pickupCount and game.pickupCount(itemId) or 1)
    end

    ------------------------------------------------------------------ bells and currency

    handlers.H = function(tag, from)
        local ghost = peerOf(from).ghost
        if valid(ghost) and game.playHitReaction and tag and tag ~= "" then
            game.playHitReaction(ghost, tag, net.moveAge())     -- (sent in the frame it began: see game.watchHitState)
        end
    end

    -- Shared boss parry/vulnerability window
    net.parrySharedAt = {}
    handlers.PARRY = function(rest, from)
        local name, tag = (rest or ""):match("^(%S+)%s*(%S*)$")
        if not name then
            return
        end
        local actor = enemyByName[name]
        if valid(actor) and not (game.isDead and game.isDead(actor)) and game.shareParryWindow then
            net.parrySharedAt[name] = os.clock()
            game.shareParryWindow(actor, tag)
        end
    end

    -- Dynamic boss summons (e.g. DangHui puppets, BiHai adds, any future boss's dynamic minions):
    -- Queued for 1.5 s so if the guest's own boss spawns its native copy we NEVER double it (no 3rd boss / 2x adds).
    net.dynSpawned, net.dynTried, net.dynPending = {}, {}, {}
    function net.clearDynSpawned(sweepNative)
        for name, rec in pairs(net.dynSpawned or {}) do
            if rec.addr and game.forgetTwin then
                game.forgetTwin(rec.addr)
            end
            if valid(rec.actor) then
                if game.hideBossBar then pcall(game.hideBossBar, rec.actor) end
                pcall(function() rec.actor:K2_DestroyActor() end)
            end
        end
        net.dynSpawned, net.dynPending, net.dynTried, net.excessSeen = {}, {}, {}, {}
        if sweepNative and not isHost() then
            for _, ch in ipairs(FindAllOf("PBZCharacter_NPC") or {}) do
                if valid(ch) then
                    local okC, cn = pcall(function() return ch:GetClass():GetFName():ToString() end)
                    if okC and type(cn) == "string" and cn:find("^BP_Monster_") and net.dynClassOK(cn) then
                        local eid = game.enemyId and game.enemyId(ch, ch:GetAddress()) or ""
                        if eid:sub(1, 3) ~= "sp:" then
                            if game.hideBossBar then pcall(game.hideBossBar, ch) end
                            pcall(function() ch:K2_DestroyActor() end)
                        end
                    end
                end
            end
        end
    end

    -- (Checked against the game's full file list: 84 of 84 player finisher animations -- ExE, SimpleExE,
    -- EXE, SpecialExE, Execution, GEx, BDEx, BEx -- and none of the combo attacks named "..._Ex_Montage".)
    function net.isExecName(n)
        if type(n) ~= "string" then
            return false
        end
        local l = n:lower()
        return l:find("exe_", 1, true) ~= nil or l:sub(-3) == "exe" or l:find("execut", 1, true) ~= nil
            or l:find("_gex_", 1, true) ~= nil or l:find("bdex", 1, true) ~= nil or l:find("_bex_", 1, true) ~= nil
            or l:find("finish", 1, true) ~= nil or l:find("chujue", 1, true) ~= nil
    end

    -- (Which runtime-spawned enemy classes get a copy in the guest's world. The game's summons are mostly
    -- named "..._Summon" (GuiChai_Black_TwinBlade_Summon, Dog_Summon, HuaShan_*_Summon, FemaleDoll_*_Summon...), which
    -- the old list missed; its cutscene and tutorial versions (ForSeq, ForTeach) and the summon helpers are left out.
    -- net.SYNC_SUMMONS = false goes back to StuntDouble/For<Boss> only.)
    -- (Off. "..._Summon" classes include the players' own Ctrl summons, so copying and pruning
    -- them as enemies made a player's summoned puppets vanish. Back to the StuntDouble/For<Boss> list.)
    net.SYNC_SUMMONS = false
    function net.dynClassOK(cls)
        if type(cls) ~= "string" or cls == "" then
            return false
        end
        if cls:find("_Stand_C$") or cls:find("ForPlayer", 1, true) or cls:find("ForSeq", 1, true)
            or cls:find("ForTeach", 1, true) or cls:find("SummonBase", 1, true) or cls:find("SummonPoint", 1, true) then
            return false
        end
        if cls:find("StuntDouble", 1, true) or cls:find("For%u") then
            return true
        end
        return net.SYNC_SUMMONS ~= false and cls:find("_Summon", 1, true) ~= nil
    end

    handlers.DYN = function(rest, from)
        if isHost() then
            return
        end
        local name, cpath, sx, sy, sz, syaw = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        local x, y, z, yaw = num(sx), num(sy), num(sz), num(syaw)
        if not (name and cpath and x and y and z and yaw and game.spawnByClass) then
            return
        end
        if enemyByName[name] ~= nil or net.hostKilled[name] or net.dynTried[name] or net.dynPending[name] then
            return
        end
        if net.localLoc and gap3d(net.localLoc, { X = x, Y = y, Z = z }) > PARTNER_REACH_CM then
            return
        end
        local cls = cpath:match("%.([^%.]+)$") or ""
        if not net.dynClassOK(cls) then
            return
        end
        local delay = cls:find("StuntDouble", 1, true) and 1.0 or (cls:find("Summon", 1, true) and 2.2 or 1.2)
        net.dynPending[name] = { cpath = cpath, class = cls, x = x, y = y, z = z, yaw = yaw, at = os.clock() + delay }
    end

    -- Enemy shield-break sync (generic across all shielded mobs)
    net.shieldSent = {}
    handlers.SHLD = function(rest, from)
        local name = (rest or ""):match("^(%S+)$")
        if not name then
            return
        end
        local actor = enemyByName[name]
        if valid(actor) and not (game.isDead and game.isDead(actor)) and game.breakEnemyShield then
            net.shieldSent[name] = os.clock()
            game.breakEnemyShield(actor)
        end
    end

    -- Player Ctrl summons (e.g. Weapon_KuYeSiZhuChuan bronze fist allies & any future boss-power summons):
    -- Visually spawned on partner's PC so both players see each other's allies fighting!
    net.ownSummons, net.remoteSummons, net.sumTickAt = {}, {}, 0
    net.MAX_SUMMONS_SHOWN, net.MAX_SUMMONS_A_SECOND, net.sumMade, net.sumMadeAt = 12, 4, 0, 0
    handlers.PSUM = function(rest, from)
        local uid, cpath, sx, sy, sz, syaw = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        local x, y, z, yaw = num(sx), num(sy), num(sz), num(syaw)
        if not (uid and cpath and x and y and z and yaw and game.spawnByClass) then
            return
        end
        local key = (from or 1) .. ":" .. uid
        if net.remoteSummons[key] and valid(net.remoteSummons[key].actor) then
            return
        end
        -- (So many at most, and so many a second: each is a body made in this world at a partner's word.)
        local shown, now = 0, os.clock()
        for _ in pairs(net.remoteSummons) do
            shown = shown + 1
        end
        if now - (net.sumMadeAt or 0) >= 1 then
            net.sumMade, net.sumMadeAt = 0, now
        end
        if shown >= net.MAX_SUMMONS_SHOWN or net.sumMade >= net.MAX_SUMMONS_A_SECOND then
            return
        end
        net.sumMade = net.sumMade + 1
        if net.localLoc and gap3d(net.localLoc, { X = x, Y = y, Z = z }) > PARTNER_REACH_CM then
            return
        end
        local actor = game.spawnByClass(cpath, x, y, z, yaw)
        if valid(actor) then
            local saddr = actor:GetAddress()
            if game.setupVisualSummon then
                game.setupVisualSummon(actor)
            elseif game.visualSummons then
                game.visualSummons[saddr] = true
            end
            local brain = game.stopAI and game.stopAI(actor) or nil
            local tnow = os.clock()
            net.remoteSummons[key] = {
                actor = actor, addr = saddr, brain = brain, at = tnow, steerAt = tnow,
                x = x, y = y, z = z, yaw = yaw, cx = x, cy = y, cz = z, cyaw = yaw
            }
        end
    end

    handlers.PSUMP = function(rest, from)
        local uid, sx, sy, sz, syaw, mpath, mpos = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+) (%S+)%s*(%S*)%s*(%S*)$")
        local x, y, z, yaw = num(sx), num(sy), num(sz), num(syaw)
        if not (uid and x and y and z and yaw) then
            return
        end
        local key = (from or 1) .. ":" .. uid
        local s = net.remoteSummons[key]
        if s and valid(s.actor) then
            s.x, s.y, s.z, s.yaw, s.at = x, y, z, yaw, os.clock()
            local pos = num(mpos)
            if mpath and mpath ~= "" and mpath ~= "-" and pos and pos >= 0 and pos < 600
                and api.moves and api.moves.allowedPath(mpath) then
                if s.mpath ~= mpath or pos < (s.mpos or 0) - 0.1 then
                    local m = api.moves.montage(mpath)
                    local ai = m and api.moves.animOf(s.actor)
                    if ai then
                        pcall(function() ai:Montage_Play(m, 1.0, 0, pos + net.moveAge(), true) end)
                        s.mpath, s.mpos = mpath, pos
                    end
                else
                    s.mpos = pos
                end
            end
        end
    end

    handlers.PSUMEND = function(rest, from)
        local uid = (rest or ""):match("^(%S+)$")
        if not uid then
            return
        end
        local key = (from or 1) .. ":" .. uid
        local s = net.remoteSummons[key]
        net.remoteSummons[key] = nil
        if s then
            if s.addr and game.visualSummons then game.visualSummons[s.addr] = nil end
            if valid(s.actor) then pcall(function() s.actor:K2_DestroyActor() end) end
        end
    end

    frameTicks.remoteSummons = function()
        if not net.enabled or next(net.remoteSummons) == nil then
            return
        end
        local now = os.clock()
        for key, s in pairs(net.remoteSummons) do
            if not valid(s.actor) then
                if s.addr and game.visualSummons then game.visualSummons[s.addr] = nil end
                net.remoteSummons[key] = nil
            else
                local dt = math.min(0.05, math.max(0.001, now - (s.steerAt or (now - 0.016))))
                s.steerAt = now
                local dx, dy, dz = s.x - (s.cx or s.x), s.y - (s.cy or s.y), s.z - (s.cz or s.z)
                local distSq = dx * dx + dy * dy + dz * dz
                local a = distSq > 640000 and 1.0 or (1 - math.exp(-16.0 * dt))
                s.cx = (s.cx or s.x) + dx * a
                s.cy = (s.cy or s.y) + dy * a
                s.cz = (s.cz or s.z) + dz * a
                local dyaw = (s.yaw - (s.cyaw or s.yaw) + 180) % 360 - 180
                s.cyaw = (s.cyaw or s.yaw) + dyaw * a
                pcall(function()
                    local cmc = s.actor.CharacterMovement
                    if valid(cmc) and cmc.MovementMode ~= MOVE_NONE then
                        cmc:SetMovementMode(MOVE_NONE, 0)
                    end
                    s.actor:K2_SetActorLocationAndRotation({ X = s.cx, Y = s.cy, Z = s.cz },
                        { Pitch = 0.0, Yaw = s.cyaw, Roll = 0.0 }, false, {}, true)
                end)
            end
        end
    end

    -- Small-enemy & boss E execution lock + visual sync (blocks double-E via execLock posture+GE removal!)
    net.ownExec, net.partnerExec, net.EXEC_LOCK_S, net.exLockNextAt = {}, {}, 4.0, 0
    handlers.EX = function(rest, from)
        local name, on, sx, sy, sz, syaw, mpath, mpos = (rest or ""):match("^(%S+) (%S+)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)$")
        if not name then
            return
        end
        local actor = enemyByName[name]
        if on == "1" then
            if net.ownExec[name] then
                -- (Both pressed E within the ping: the host's finisher wins, the guest's yields.)
                if isHost() then
                    return
                end
                net.ownExec[name] = nil
            end
            if valid(actor) and game.isDead and game.isDead(actor) then
                return
            end
            net.partnerExec[name] = os.clock() + net.EXEC_LOCK_S
            if valid(actor) then
                if game.execLock then
                    game.execLock(actor, true)
                end
                local x, y, z, yaw = num(sx), num(sy), num(sz), num(syaw)
                if x and y and z and yaw then
                    pcall(function()
                        actor:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z },
                            { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false, {}, true)
                    end)
                end
                local pos = num(mpos)
                if mpath and mpath ~= "" and mpath ~= "-" and pos and pos >= 0 and pos < 600
                    and api.moves and api.moves.allowedPath(mpath) then
                    local m = api.moves.montage(mpath)
                    local ai = m and api.moves.animOf(actor)
                    if ai then
                        local cur = ai:GetCurrentActiveMontage()
                        if not (valid(cur) and cur:GetAddress() == m:GetAddress()) then
                            pcall(function() ai:Montage_Play(m, 1.0, 0, pos + net.moveAge(), true) end)
                        end
                    end
                end
            end
        else
            net.partnerExec[name] = nil
            if valid(actor) and game.execLock then
                game.execLock(actor, false)
            end
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
        net.unsettle()      -- (a rest: enemies back, and every "no" heard is old news, a party's rest too)
        if whose then
            endFights(whose)
            game.forgetFocus()
            handover.reset()
            return
        end
        endFights(nil)      -- (their mirrored bars go too: with elsewhere no resetBosses ran, and a bar stayed up for good)
        net.pendingBosses = {}
        net.partnerBosses = {}
        net.struck = {}
        net.hostBosses = {}
        net.hitHere = {}
        net.fightOf = {}
        net.notOnHost = {}
        net.bossAsk = {}
        net.joinedBoss, net.joinedWith, net.farFight, net.lastFarFight = nil, nil, nil, nil
        reopenFog()
        if game.resetBosses and not elsewhere then
            game.resetBosses()
        end
        game.forgetFocus()
        handover.reset()
    end

    -- A death respawn refreshes the dying player's own world (the game does that, as in single-player).
    --   Host died: its world is everyone's truth, so the client's world refreshes too ("R death"): like the host
    --     dying in Elden Ring co-op, the fight starts over for both.
    --   Client died: only the client's world refreshed. The host's world, and its boss fight, go on untouched;
    --     the client's copies of what the host already killed are killed again, and a boss fight the host is
    --     still in is shown again (bar and fog walls).
    local restListeners = {}   -- name -> function(kind): a rest, here or the partner's (revive.lua): bell, death, sit (this
                                -- player's own, or a partner's that rests them in a boss fight), partnersit (any partner's), gone

    local function restEvent(kind)
        for _, fn in pairs(restListeners) do
            fn(kind)
        end
    end

    local function onLocalRest(kind)
        if net.arena then
            -- (A PvP match: the world is the same, nothing to refresh anywhere. A real death there is the match's to deal with.)
            if api.arena and api.arena.restDuring then
                api.arena.restDuring(kind)
            end
            return
        end
        net.unsettle()
        -- (A guest's own death refreshes only its own world: the host's enemies, and their twins, go on.)
        net.restRefreshes = isHost()
        -- (Every enemy of this world is made anew: none is one seen alive, whatever stood at its address. net.metDead.)
        net.livedAt, net.livedAs = {}, {}
        restEvent(kind)
        if kind == "death" and net.role == "client" then
            log("You died and respawned: your world refreshed, the host's goes on. Enemies the host already killed stay dead.")
            if net.clearDynSpawned then net.clearDynSpawned(true); if game.after then game.after(1.2, function() if net.clearDynSpawned and next(net.partnerBosses) == nil then net.clearDynSpawned(true) end end) end end
            handover.live = {}      -- (every enemy here is a new one: none is this game's own to run yet, handover.byHere)
            local again = 0
            for name in pairs(net.hostKilled) do
                net.pendingDeaths[name] = true
                again = again + 1
            end
            -- (Only fights still on: one the host never joined, or walked out of, came back as a bar and shut walls with
            -- nobody's fight behind them. Another guest's that's on comes back too: its walls went with the rest.)
            for _, name in ipairs(net.stillFought()) do
                -- (Not this player's own fight, announced to the host: the host mirrors it, and it came back here as the
                -- host's, its bar up again over nobody's fight.)
                if not (net.ownAnnounced or {})[name] then
                    net.pendingBosses[name] = true
                end
            end
            -- (This player's own fights end with the death: their marks as the host's go too, or the next death queued
            -- one again while the host fought anything, and its bar came back over nobody's fight.)
            for name in pairs(net.ownAnnounced or {}) do
                net.hostBosses[name] = nil
            end
            net.ownAnnounced = {}
            net.struck = {}         -- (out of every fight it was in: see net.fightingHere)
            -- (A fight this player had walked into is theirs to walk into again: still marked joined, E at the wall did
            -- nothing until the boss died, and an arena apart took them back to the partner after it.)
            net.joinedBoss, net.joinedWith, net.joinedFar, net.bossOverAt = nil, nil, nil, nil
            -- (And F3 back into it, for an arena only a trip reaches: the way in was used up by the first one.)
            local far = net.lastFarFight
            if far and net.partnerBosses[far.name] then
                net.farFight = far
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
            -- (And what else was kept of the old ones by their addresses, which the new ones often take: who hit which, which
            -- copy went with which of the host's, what's an enemy and what's a boss, which bar is only shown for a
            -- partner's fight, which boss was brought out for one. "Many things gets lost after the guest dies", the
            -- owner, 11-15; the audit of that day.)
            game.forgetFocus()
            net.matchSticky, net.stickySeen = {}, {}
            net.spawnedFor, net.extraBossWatch = nil, nil
            if game.forgetActors then
                game.forgetActors()
            end
            if game.forgetMirrors then
                game.forgetMirrors()
            end
            -- (A fight shown here that isn't coming back now, its player down and waiting say, is let go: kept, its B told
            -- again later was dropped as shown already, and the fight had a bar here and no walls. Ended as any fight is,
            -- its copy back on its own side if it was put on the enemy's for it, game.enemySide: dropped bare, a figure this
            -- world hasn't started stayed an enemy with no fight, alone after co-op too. The fifth review.)
            for name in pairs(net.partnerBosses) do
                if not net.pendingBosses[name] then
                    endBossFight(name, enemyByName[name])
                    net.fightOf[name] = nil
                end
            end
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
        -- (A guest's: the host's fight, or another guest's, goes on. Wiped with the rest, it was gone from this screen for
        -- good, as B is told once.)
        local still = {}
        if isClient() or net.party then     -- (a party host's rest leaves a guest's fight going too)
            for _, name in ipairs(net.stillFought()) do
                still[name] = { p = net.partnerBosses[name], h = net.hostBosses[name], f = net.fightOf[name] }
            end
        end
        forgetDeaths(kind)
        for name, s in pairs(still) do
            net.partnerBosses[name], net.hostBosses[name], net.fightOf[name] = s.p, s.h, s.f
            net.pendingBosses[name] = true
        end
        net.killsFrom = link.now() + net.LINES_AFTER_S      -- (net.lateKill)
        net.worldNew(nil)
        sendEvent("R", kind)
    end

    -- Host: a killing blow read now is of a body that's gone. A guest tells one as its copy stands at its floor, and
    -- one told before the host's word of its world's refresh reached that guest is read here after the refresh, where
    -- the new, whole body bears the name: taken, it was the fresh boss's death in both worlds, its pay out and
    -- "beaten" in the host's save, by one plain blow (383's fight starting over, or any respawn of the host's with a
    -- guest striking: a copy at 2 is struck till the word comes. The tenth review, on the base too). From this
    -- world's refresh (pbz.lua's game.refreshedHere, half a second before R is told, a load's stall longer: for
    -- REFRESH_TOLD_S at most) till LINES_AFTER_S after R has gone, the twin of a guest's half second
    -- (net.dropHostLines): a plain blow then, and a real one is told again and taken. (A boss has a rule of its own
    -- besides, for all time, in handlers.D: a killing blow on one with more than half its health, by a blow that took
    -- less than half of that, is a plain blow. For a day it was a clock, ten seconds from the refresh: a link quiet
    -- for longer than that sent the old body's killing blows after it. REVIEW-10.)
    net.REFRESH_TOLD_S = 60.0
    function net.lateKill()
        if not isHost() then
            return false
        end
        local at = game.refreshedHere
        return (at ~= nil and os.clock() - at < net.REFRESH_TOLD_S) or link.now() < (net.killsFrom or 0)
    end

    -- Host: a killing blow read from a guest not heard for GAP_KILL_AFTER_S, or heard again less than GAP_KILL_S ago,
    -- was told in that gap, where the guest heard nothing of this world either. Its copy stood at this world's
    -- numbers from before the gap, lifted back to them each second, and the boss here can be another by then: a new
    -- body (the host down and held, the guest taken for gone at 12 s, the hold let go, the respawn's refresh inside the
    -- gap), or the same one made whole by its own game as the guest's figure went quiet (the bench, run223: the Axe
    -- chief from 2 to 27680, the host down). The relay keeps what a guest tells for as long as the gap lasts and sends
    -- it all as the link comes back, plain blows and killing blows in their order: the plain ones took the boss under
    -- half, where the rule by the blow (handlers.D) no longer holds, and the next killing blow was its end in both
    -- worlds, its pay out and "beaten" in both saves (the tenth review's run-checkers, and the review of 401). A plain
    -- blow then, answered with what this one has; the next one, struck with the link up, is taken. From 3 s: a boss
    -- here resets only once the guest's figure has been quiet that long (FIGHT_SILENT_S), and a hiccup of a second or
    -- two is common: a killing blow across one of 2.5 s still lands at once (the sim). A stall of this game's own
    -- counts the same: what came in it is read late. Not a finishing move of theirs (X): that's its end, the user's
    -- word, and handlers.D's own checks hold it where it isn't. Not judged: the gap's plain blows, which land on
    -- the body that's here (a guest's own damage, no more), and a guest's own kill in a world it ran alone (GK),
    -- which counts as it did. (A frame takes its events before the partner's place: the first after a gap still
    -- has the old time here. backAt: heard, below.)
    net.GAP_KILL_AFTER_S, net.GAP_KILL_S = 3.0, 1.5
    function net.gapKill(from)
        local p = isHost() and peerOf(from) or nil
        if p == nil or p.lastRemoteAt == nil then
            return false
        end
        local now = os.clock()
        return now - p.lastRemoteAt > net.GAP_KILL_AFTER_S or now - (p.backAt or -1e9) < net.GAP_KILL_S
    end

    -- Host: this world refreshed, and the guests are told (R, or RH for a party guest's rest; but: the guest whose
    -- rest it was, who knows). When, by guest: net.gapOld.
    function net.worldNew(but)
        if isHost() then
            for _, p in ipairs(partners()) do
                if but == nil or p.number ~= but then
                    p.worldNewAt = os.clock()
                end
            end
        end
    end

    -- Host: what a guest told of its blows in a gap of its link in which this world refreshed was struck at bodies
    -- that are gone, plain blows and killing blows alike: none of it is taken. The host down and held, the
    -- guest quiet for 18 s: at 12 s the hold lets go, the respawn refreshes this world, and the guest's 18 s of blows
    -- at the old boss, kept by the relay, were read on the new one as the link came back: 6300 of its 7500 gone
    -- before its fight had begun (the sim). The guest's game hears of the refresh in the same moment, and what it
    -- tells from there is of the new ones. Without a refresh in it, a gap's plain blows are the guest's own damage on
    -- the body that's still here, and are taken; its killing blows are net.gapKill's. (Its own kill of an enemy it
    -- ran alone, GK, counts as it did: the relay gives it to a party's other guests whatever is done with it here,
    -- and refused here alone the worlds would disagree.) what: for the log, once a gap.
    function net.gapOld(from, what)
        local p = isHost() and peerOf(from) or nil
        if p == nil or p.lastRemoteAt == nil or p.worldNewAt == nil then
            return false
        end
        local now = os.clock()
        local old
        if now - p.lastRemoteAt > net.GAP_KILL_AFTER_S then
            old = p.worldNewAt > p.lastRemoteAt         -- (not heard since before the refresh)
        else
            old = now - (p.backAt or -1e9) < net.GAP_KILL_S and p.worldNewAt > (p.gapFrom or math.huge)
        end
        if old and now - (p.oldSaidAt or -1e9) > 5 then
            p.oldSaidAt = now
            log("What the other player told in a gap of theirs, this world refreshed meanwhile, is of what's gone: not taken ("
                .. tostring(what) .. " the first).")
        end
        return old
    end

    -- The fights of others this player is shown that are still on (their player's bar is up): names.
    function net.stillFought()
        local out, seenName = {}, {}
        for _, list in ipairs({ net.partnerBosses, net.hostBosses }) do
            for name in pairs(list) do
                if not seenName[name] then
                    seenName[name] = true
                    local on
                    if net.party then
                        on = peerOf(net.fightOf[name] or 1).fights
                    else
                        on = net.partnerFighting
                    end
                    if on then
                        out[#out + 1] = name
                    end
                end
            end
        end
        return out
    end

    -- The bosses of a fight of this player's own, alive: not copies of another player's fight.
    function net.ownBosses()
        local own = {}
        for _, actor in ipairs(game.bossActors and game.bossActors() or {}) do
            local mirrored = false
            for name in pairs(net.partnerBosses) do
                mirrored = mirrored or enemyByName[name] == actor
            end
            -- (Or a bar this mod put up for a partner's fight, whatever actor it's on: a copy that lost its pairing, this
            -- player more than 60 m off, kept its bar and read as a fight of this player's own. The game's own bar on it
            -- makes it this game's: see pbz.lua's hook.)
            if not mirrored and game.isMirrorBar and game.isMirrorBar(actor) then
                mirrored = true
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
        -- A guest hearing another guest's rest, passed on: whether the host's world refreshed for it is the host's to say
        -- (RH). Taken as so, the host's kills were forgotten and this world refreshed when the host's hadn't, its enemies
        -- back here for good. Only that player's fights end.
        if isClient() and from then
            net.restRefreshes = false
            restEvent(kind)
            endFights(from)
            game.forgetFocus()
            handover.reset()
            return
        end
        -- From another map it says nothing about the enemies here, or the fight this player may be in.
        local elsewhere = not sameMap(peerOf(from).target)
        -- Nor, at a bell, about a boss fight of this player's own (not a copy of one of theirs): a partner resting isn't in it.
        -- Its bar came down and every monster came back mid-fight. (A host's death is everyone's: that one ends it.)
        local ownFight = kind ~= "death" and not elsewhere and #net.ownBosses() > 0
        -- (Nor during another player's fight here, in a party: a third player's rest refreshed the boss under them.)
        if kind ~= "death" and not elsewhere and net.party then
            for _, name in ipairs(net.stillFought()) do
                if net.fightOf[name] ~= (from or 1) then  -- (the host's own fight is fightOf 1, its events from nil)
                    ownFight = true
                end
            end
        end
        elsewhere = elsewhere or ownFight
        -- (Said before the listeners hear it: whether this world's enemies come back, which is what the twins go by.)
        -- (On a guest, the host's own word only: another guest's rest, passed on, says nothing of whether the host's world
        -- refreshed, and twins taken away then could never come back here.)
        net.restRefreshes = not elsewhere and (isHost() or from == nil)
        restEvent(kind)
        if kind == "death" then
            log("The host died and respawned: enemies respawn here too.")
            if net.clearDynSpawned then net.clearDynSpawned(true); if game.after then game.after(1.2, function() if net.clearDynSpawned and next(net.partnerBosses) == nil then net.clearDynSpawned(true) end end) end end
        else
            log("The other player rested at a bell: respawning enemies here too.")
            if net.clearDynSpawned then net.clearDynSpawned(true); if game.after then game.after(1.2, function() if net.clearDynSpawned and next(net.partnerBosses) == nil then net.clearDynSpawned(true) end end) end end
        end
        if ownFight then
            log("A boss fight of your own is on: it goes on, and enemies here come back at the next rest.")
            if isHost() and kind ~= "death" then
                -- (The resting guest's world refreshed all the same, and it forgot the host's kills: they're told again,
                -- or what the host had killed stood alive there.)
                for name in pairs(net.deadSent) do
                    if from then
                        sendTo(from, "K", name)
                    else
                        sendEvent("K", name)
                    end
                end
            end
        end
        local still = {}
        if net.party and from == nil then   -- (the host's rest ends the host's fights only, not another guest's here)
            for _, name in ipairs(net.stillFought()) do
                if (net.fightOf[name] or 1) ~= 1 then
                    still[name] = { p = net.partnerBosses[name], h = net.hostBosses[name], f = net.fightOf[name] }
                end
            end
        end
        forgetDeaths(kind, elsewhere, net.party and from or nil)
        for name, st in pairs(still) do
            net.partnerBosses[name], net.hostBosses[name], net.fightOf[name] = st.p, st.h, st.f
            net.pendingBosses[name] = true
        end
        seen = {}
        if isClient() and not elsewhere then
            net.dropHostLines()     -- (the host's lines from before say nothing of what stands here from now)
        end
        if game.refreshEnemies and not elsewhere then
            game.refreshEnemies()
            if isHost() then
                net.killsFrom = link.now() + net.LINES_AFTER_S      -- (net.lateKill)
            end
        end
        if isHost() and net.party and from and not elsewhere then
            net.worldNew(from)
            sendEvent("RH", kind, from)     -- (the host's world refreshed for that guest's rest: the other guests' do too)
        end
    end

    -- Host: its world refreshed for a guest's rest (slot). The other guests' worlds follow, as for the host's own.
    handlers.RH = function(rest, from)
        local kind, slot = (rest or ""):match("^(%a+) (%d+)$")
        slot = tonumber(slot)
        if from ~= nil or not isClient() or not kind or slot == net.slot then
            return
        end
        local elsewhere = not sameMap(peerOf(nil).target) or #net.ownBosses() > 0
        net.restRefreshes = not elsewhere
        restEvent(kind)
        log("Player " .. slot .. " rested at a bell: the host's world refreshed, enemies respawn here too.")
        forgetDeaths(kind, elsewhere, slot)
        seen = {}
        if not elsewhere then
            net.dropHostLines()
        end
        if game.refreshEnemies and not elsewhere then
            game.refreshEnemies()
        end
    end

    -- A boss back to full health, if it's there and alive. (Fields, not locals: this function is at its 200.)
    function net.bossFull(actor)
        if valid(actor) and not game.isDead(actor) and game.setHealth then
            local _, maxhp = game.getHealth(actor)
            if maxhp and maxhp > 0 then
                game.setHealth(actor, maxhp)
                return true
            end
        end
        return false
    end

    -- Any sit: the bosses of fights still on back to full health, in the world that runs them, and this world's copies of
    -- the fights this player is in. True if this player is in one. Their own (a bar of this game's); the ones they started
    -- (net.bossesTold: its bar goes with their death, the fight going on with the others, the boss still this world's); on
    -- the host every partner's fight, run on this world's actor; and a partner's fight they joined or struck, on its copy
    -- here (the copy is the boss when the host is far off). Reviews, 11-12: a guest's own fight on a boss the host's world
    -- runs, its copy put back alone and taken down again by the next line, the guest told it was full; a party's host down
    -- and waiting in its own fight, its boss left as it was; a guest's copy of a fight far from the host, the same.
    function net.sitBossesToFull()
        local inFight = false
        for _, boss in ipairs(net.ownBosses()) do
            net.bossFull(boss)
            inFight = true
        end
        for name in pairs(net.bossesTold or {}) do
            net.bossFull(enemyByName[name])
        end
        -- (On the host, a partner's fight this world ran, ended with its boss alive: they walked out or died, the boss left
        -- as it was here, and a sit then back in found it so. A review, 11-12. A fresh one is full already.)
        for name in pairs(isHost() and net.bossesSeen or {}) do
            net.bossFull(enemyByName[name])
        end
        for name in pairs(net.partnerBosses) do
            local mine = net.joinedBoss == name or net.struck[name]
            if mine or isHost() then
                net.bossFull(enemyByName[name])
            end
            if mine then
                inFight = true
            end
        end
        return inFight
    end

    -- A sit at a bell brings everyone together: whoever's dead or watching a fight comes to the one who sat. Anyone else is
    -- rested only in a boss fight of their own, the fight starting over: they're rested and the boss is back to full health
    -- (the user, 11-12: "you heal back and the boss goes full"); out of one nothing changes for them, each resting at their
    -- own sit, as in the game ("Nothing, own sit only"). One who's down stays down (their pick). Any sit puts the bosses of
    -- fights back to full health, in the world that runs them ("a sit should make boss health go full i am scared people
    -- will abuse it": a sit, then back into the fight). It says the sitter's fight is over too, or a bar left up there would
    -- hold a partner's respawn for good.
    local function onLocalSit()
        if net.arena then
            if api.arena and api.arena.restDuring then     -- (a bell in a PvP match heals nobody else: it's a forfeit)
                api.arena.restDuring("sit")
            end
            return
        end
        -- (Not a bell's rest that came with this player's respawn: told as a sit, it put the host's boss back at full health
        -- (handlers.SIT). The review of the report "After my teammate died, he instantly respawned" on 1.6.6.)
        if net.deadSince ~= nil or os.clock() - (net.upAt or -1e9) < 3 then
            log("A bell's rest came with this player's respawn: not told as a sit.")
            return
        end
        restEvent("sit")
        if not net.pvp then
            net.sitBossesToFull()       -- (with PvP on a partner's sit was never heard of: as before)
        end
        if game.resetBosses then
            game.resetBosses()
        end
        net.fightHereAt = nil
        if game.cleanBossBars and not (game.bossFightActive and game.bossFightActive()) and next(net.partnerBosses) == nil then
            game.cleanBossBars(true)
        end
        log("Sat at a bell: telling the other player.")
        sendEvent("SIT")
    end

    handlers.SIT = function(_, from)
        local p = peerOf(from)
        p.fights = false
        countFights()
        restEvent("partnersit")         -- (not "sit": no rest here but a boss fight's, revive.lua's down count included)
        -- (Before the sitter's fights end here: theirs is reset too, a sit then back in finding it full, and this player's
        -- part in it is still known. Not with PvP on, nor in a match: a partner's sit did nothing there, as before.)
        local inFight = not (net.pvp or net.arena) and net.sitBossesToFull()
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
        elseif inFight and not (api.revive and api.revive.isDown and api.revive.isDown()) then
            -- In a boss fight the fight starts over: their own, or a partner's they joined or struck (a helper in the host's
            -- fight has no boss of their own here: a review, 11-12). Rested (health, the gourd to its whole size) as the boss
            -- went back to full above (the user, 11-12: "you heal back and the boss goes full"). Out of one, nothing: a
            -- partner's sit refilled every gourd, so a gourd held more drinks than it has (or, with extra drinks, fewer), the
            -- 1.7.1 report's "5 uses to 1 use".
            game.restHere(pawn)
            restEvent("sit")            -- (rested as a sit would: Revive's down count cleared too, as 1d53bad's sit did)
            log("The other player sat at a bell during your boss fight: you're rested, and so is the boss.")
            api.status.notify("rest", who .. " rested at a bell: you're rested, and so is the boss.")
        end
        log("The other player sat at a bell.")
    end

    -- The host's world is everyone's truth. Loaded anew (it restarted, or left to the title screen and came back) it has
    -- everything alive again, so this world refreshes too, or what died here would stay alive there and unseen here.
    handlers.Y = function(world, from)
        if from ~= nil then
            return          -- (the host's word only: another guest's, passed on by the relay, is no host's)
        end
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

    -- A boss that fell in a fight here a moment ago: maybe one that gets up again in the same fight (Xiaoxue). Not said to be
    -- beaten meanwhile (HAS, B): the guest's copy was killed on sight and the boss vanished there for good. (Host, its own
    -- clock: os.clock.)
    net.FALL_GRACE_S = 90
    function net.fellLately(name)
        local at = net.fellInFight and net.fellInFight[name]
        return at ~= nil and os.clock() - at < net.FALL_GRACE_S
    end

    -- A guest asks after an enemy of its own. Anything loaded here counts, however far from this player: only "no" is sent.
    handlers.HAS = function(name, from)
        if not isHost() then
            return
        end
        -- (Not while this world is still settling, after a load, a rest or a trip: its enemies there aren't all in, or not yet
        -- known by their spawner, and a "no" hid an enemy it had on the guest's screen: invisible enemies after a teleport or a
        -- bell. The guest asks again.)
        if os.clock() < (net.unsettledUntil or 0) then
            return
        end
        -- (Nor of a name that is the asker's own alone, an older guest's for a spawner its game made as it ran, a
        -- mount's: this world's has another name, and a "no" hid the guest's horse under its rider. Nothing said. 410.)
        if net.ownName(name) then
            return
        end
        -- (A fresh read at most once a second: a round of asks came together, and each one's full search hitched the host.)
        local fresh = os.clock() - (net.hasFreshAt or -9) > 1
        if fresh then
            net.hasFreshAt = os.clock()
            if game.refreshEnemyIds then
                game.refreshEnemyIds(true)
            end
        end
        local list, addrs = game.listEnemies(fresh)
        for i, actor in ipairs(list) do
            if valid(actor) and enemyName(actor, addrs[i]) == name and not game.isDead(actor) then
                return
            end
        end
        if net.fellLately(name) then
            return          -- (down a moment, maybe getting up: nothing said; the guest asks again)
        end
        -- (Nor for one this world has alive and put away: its camp's enemies are out only while this player is in the
        -- camp's area. "No" hid them on a guest who walked in first, the host a few steps outside: the guest's enemies
        -- gone from the screen for 25 s at a time, the fight with them. Nothing said: they're the guest's own till this
        -- player is in there too.)
        if game.sleepsHere and game.sleepsHere(name, select(2, getPlayer1())) then
            return
        end
        if game.isBeaten and game.isBeaten(name) then
            tellBeaten(name, from)
        elseif from then
            sendTo(from, "NOT", name)
        else
            sendEvent("NOT", name)
        end
    end

    handlers.NOT = function(name, from)
        if from ~= nil then
            return          -- (the host's word only: another guest's, passed on by the relay, is no host's)
        end
        -- (When, on setAside's clock, the link's: os.clock() counts from the game's start, the link from the mod's, and a "no"
        -- lived 25 s and all the game's start-up time on top.)
        net.notOnHost[name] = net.frameNow or link.now()
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
        net.unsettle()
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
        if game.inPrologue and game.inPrologue() then
            return          -- (no partner's boss in the prologue: its end gives back the starting gear, the gourd among it)
        end
        -- (Another guest's fight, on a guest: only the host's world can say the boss lives, so one this save has beaten
        -- isn't brought back for it. The host tells everyone if it's beaten there.)
        local at, turned = nil, false
        -- (On the host, never a later phase of a boss of phases: those are its own fight script's to spawn, after its scene. A
        -- guest through a phase change first had the host's next phase spawned in the middle of the host's own scene, and the
        -- one the host then killed wasn't the one its story waited for. A first phase, or a boss of one, is spawned as ever:
        -- most story bosses come from a sequence spawner, "_Seq" in their name.)
        local phase = not isClient() and game.isLaterPhase and game.isLaterPhase(name)
        local spawned = nil
        if game.spawnBoss and not phase then
            at, turned, spawned = game.spawnBoss(name, not (isClient() and p ~= net))
        end
        if type(spawned) == "table" then
            -- (Watched a while: this world's own fight scene can bring the same boss in after, and the one spawned here for
            -- the partner's fight then goes: see extraTicksEarly.extraBosses.)
            spawned.untilAt = os.clock() + 120
            net.extraBossWatch = net.extraBossWatch or {}
            net.extraBossWatch[name] = spawned
            -- (And kept for the whole fight: one still standing when that fight ends without its death goes, endBossFight. One
            -- not in yet has no address to know it by.)
            if spawned.addr then
                net.spawnedFor = net.spawnedFor or {}
                net.spawnedFor[name] = { addr = spawned.addr, fname = spawned.fname, class = spawned.class }
            end
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
        if not at or not valid(pawn) or game.isDead(pawn) then
            return
        end
        if p.ghostHidden == nil then
            -- (Just linked, the partner's figure not made yet: the way in is kept for F3 all the same, a joiner's while it
            -- watches the fight. Returned before it, F3 did nothing till the watch let go.)
            net.farFight = { name = name, p = p, at = { X = at.X, Y = at.Y, Z = at.Z } }
            net.lastFarFight = net.farFight
            return
        end
        if gap3d(pawn:K2_GetActorLocation(), at) > BOSS_JOIN_CM then
            net.farFight = { name = name, p = p, at = { X = at.X, Y = at.Y, Z = at.Z } }
            api.status.notify("join", "your partner is in a boss fight: F3 takes you there, if you want to join.")
        else
            -- (F3 too: an arena some players reach by a trip of the game's, with no wall to press E at, shut a guest out who
            -- had beaten that boss in their own save: "he teleported into the arena, but I couldn't enter".)
            net.farFight = { name = name, p = p, at = { X = at.X, Y = at.Y, Z = at.Z } }
            -- (Not for a boss that fell here a moment ago and is up again, a rise: this player was by its fight, most
            -- often in it, and was told to press E at a wall they stood inside. The bench, 11-18, Xiao Xue's.)
            -- (Nor to one whose own game began that fight as the partner's did, their scenes ending together (402):
            -- told to press E at a wall they stood inside.)
            local mine = enemyByName[name]
            local begun = valid(mine) and game.bossAt and game.bossAt(mine:GetAddress(), mine)
                and not (game.isMirrorBar and game.isMirrorBar(mine))
            if not begun and not (net.killedAt and net.killedAt[name] and os.clock() - net.killedAt[name] < net.RISE_S) then
                api.status.notify("join", "your partner is in a boss fight: press E at the black wall, or F3, to join.")
            end
        end
        net.lastFarFight = net.farFight     -- (F3 back in after a death here: see onLocalRest)
    end

    -- A joiner held watching a partner's fight goes in by F3 or E: the watch ends there. (Left on, partner.check held them
    -- again within half a second: frozen in the arena, the camera on the partner, at 1 health, till the fight ended. Not
    -- watchFight(false): its resetBosses took down the bar of the fight they were going into.) watchGaveUp: no hold again,
    -- and no trip after it, for this link.
    function net.endWatch(pawn)
        if not net.watchingFight then
            return
        end
        net.watchingFight, net.watchHeld, net.watchGaveUp = false, false, true
        game.spectate(nil)
        if valid(pawn) then
            game.setMinHealth(pawn, 0)
        end
        log("Into the fight: no longer watching it.")
    end

    -- F3 during a partner's fight in an arena apart from the map. True if it took this player there. (Not TP > PARTNER:
    -- there's no other way in.)
    local function joinFarFight()
        local far = net.farFight
        local controller, pawn = getPlayer1()
        if not (far and net.partnerBosses[far.name] and valid(pawn)) or game.isDead(pawn) then
            return false
        end
        -- (joinPartner's guards: F3 skipped them all, and took a guest out of the prologue, a scene or a fight of their own.
        -- False here, joinPartner says why.)
        -- (A fight of this player's own, not any bar: the one shown here for the partner's fight counts as a bar, and a guest
        -- by the place the host was taken in, its copy within reach, could never F3 in: report A1 of the forest, again.)
        if (game.inCutscene and game.inCutscene()) or net.pvp or (game.inPrologue and game.inPrologue())
            or (#net.ownBosses() > 0 and not net.watchingFight) or os.clock() < (net.travelUntil or 0)
            or api.gs():IsGamePaused(controller) or api.localcoop.bellMenuUp() or api.localcoop.screenUp() then
            return false
        end
        net.farFight = nil
        -- (Beside the fight already, within 60 m of its place or of the partner: in without the trip, pull request
        -- 20. The rest as ever: returning false there left a joiner held watching where F3 is their way in, the
        -- report endWatch is for, and the Dragon Pillar's second player out of the fight they came to join, 419.)
        local curLoc = pawn:K2_GetActorLocation()
        -- (Not one held watching: frozen where they joined, the trip's arrival is what sets them on their feet.)
        local beside = not net.watchingFight
            and ((far.at and gap3d(curLoc, far.at) <= 6000) or (net.target and gap3d(curLoc, net.target) <= 6000)) or false
        log("Joining the other player's boss fight, " .. (beside and "from beside it." or "in an arena apart from the map."))
        net.joinedBoss, net.joinedWith, net.joinedFar = far.name, far.p, not beside
        net.endWatch(pawn)
        net.arrival = nil
        if not beside then
            arriveAt(pawn, far.at)
        end
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
                net.endWatch(pawn)
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
    net.PROLOGUE_TIP = "you're in the prologue: finish it first, or start a New Game and choose the game's own skip there."
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
        -- (Not into the prologue: the partner's prologue map is theirs alone.)
        local tmap = tostring(t.Map or "")
        if tmap:find("ZhuLinGuWu", 1, true) or tmap:find("ZLGW", 1, true) then
            return "your partner is still in the prologue."
        end
        -- (Not out of the prologue: a guest taken from it skipped the end that gives back the starting gear and the gourd,
        -- and a skip of our own (1.6.5) left the prologue's young body. The game's own skip, at New Game, does it right.)
        if game.inPrologue and game.inPrologue() then
            return net.PROLOGUE_TIP
        end
        if t.Hp == nil or t.Hp <= 0 or t.Cine then
            return "your partner can't be joined right now."
        end
        if os.clock() < (net.travelUntil or 0) then
            return nil              -- (on the way already: a second press in the loading screen began the trip again)
        end
        if not (math.abs(t.X) < 1e8 and math.abs(t.Y) < 1e8 and math.abs(t.Z) < 1e8) then
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
        -- (F3 into a fight there: a joiner's watch of it ends with the trip, as F3 into one on this map ends it. Kept on,
        -- they landed in it told as out of it, F 0 whatever they struck: the host's death there wasn't held for them,
        -- and the boss kept one player's numbers. The main session's second review, 11-16.)
        if net.partnerFighting then
            net.endWatch(pawn)
        end
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
        -- The boss is dead and the partner has gone back to the map: don't leave this player stranded in the arena. (Not in
        -- a scene or a fight of this player's own: one taken out mid-outro, or mid-fight once the partner's F dropped. Put
        -- off 2 s at a time, given up 120 s after it was first due.)
        if net.bossOverAt and os.clock() >= net.bossOverAt and ((game.sequenceOn and game.sequenceOn())
            or (game.inCutscene and game.inCutscene()) or #net.ownBosses() > 0) then
            net.bossOverFirst = net.bossOverFirst or net.bossOverAt
            if os.clock() - net.bossOverFirst < 120 then
                net.bossOverAt = os.clock() + 2
            else
                net.bossOverAt, net.bossOverFirst = nil, nil
            end
        end
        if net.bossOverAt and os.clock() >= net.bossOverAt then
            net.bossOverAt, net.bossOverFirst = nil, nil
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
    extraTicksEarly.playerSummons = function()
        if not (net.enabled and game.isPlayerSummon and game.classPathOf) then
            return
        end
        local now = os.clock()
        -- Fast ~16 Hz pose + montage stream ONLY for already-discovered active own Ctrl summons (no FindAllOf!)
        if next(net.ownSummons) ~= nil and now >= (net.sumSendAt or 0) then
            net.sumSendAt = now + 0.06
            for uid, ch in pairs(net.ownSummons) do
                if ch ~= true and valid(ch) and not (game.isDead and game.isDead(ch)) then
                    local okL, l = pcall(function() return ch:K2_GetActorLocation() end)
                    local okR, r = pcall(function() return ch:K2_GetActorRotation() end)
                    if okL and l then
                        local yaw = (okR and r and r.Yaw) or 0
                        local mpath, mpos = "-", 0
                        if api.moves then
                            pcall(function()
                                local ai = api.moves.animOf(ch)
                                local m = valid(ai) and ai:GetCurrentActiveMontage()
                                if valid(m) then
                                    local p = api.moves.pathOf(m)
                                    if api.moves.allowedPath(p) then
                                        mpath, mpos = p, ai:Montage_GetPosition(m) or 0
                                    end
                                end
                            end)
                        end
                        sendEvent("PSUMP", uid, string.format("%.0f %.0f %.0f %.0f %s %.2f", l.X, l.Y, l.Z, yaw, mpath, mpos))
                    end
                elseif ch ~= true then
                    net.ownSummons[uid] = nil
                    sendEvent("PSUMEND", uid)
                end
            end
            if next(net.ownSummons) ~= nil and game.noteLocalMove then
                game.noteLocalMove()
            end
        end
        if now < (net.sumTickAt or 0) then
            return
        end
        local active = next(net.ownSummons) ~= nil or next(net.remoteSummons) ~= nil
            or next(net.dynPending or {}) ~= nil or next(net.dynSpawned or {}) ~= nil
        net.sumTickAt = now + (active and 0.30 or 0.55)
        local _, pawn = getPlayer1()
        local dead = not valid(pawn) or (game.isDead and game.isDead(pawn))
        local spectating = dead and net.holdWanted and game.isSpectating and game.isSpectating()
        -- 1. Guest: process queued dynamic boss summons (only spawn if local class count < host class count!)
        local refLoc = (spectating and net.target and net.target.X) and net.target or net.localLoc
        if not isHost() and (not dead or spectating) and refLoc then
            local spawnedByClass = {}
            for name, q in pairs(net.dynPending or {}) do
                if enemyByName[name] ~= nil or net.hostKilled[name] then
                    net.dynPending[name] = nil
                elseif now >= q.at then
                    net.dynPending[name] = nil
                    local rSelf = net.remoteEnemies[name]
                    if rSelf ~= nil and (rSelf.Hp or 0) > 0 then
                        local sx, sy, sz = rSelf.X or q.x, rSelf.Y or q.y, rSelf.Z or q.z
                        local syaw = rSelf.Yaw or q.yaw
                        if gap3d(refLoc, { X = sx, Y = sy, Z = sz }) <= 5500 then
                            net.dynTried[name] = now
                            local locCnt, remCnt = 0, 0
                            for _, r in pairs(net.remoteEnemies) do
                                if r.Class == q.class and (r.Hp or 0) > 0 and r.X and gap3d(refLoc, r) <= 5500 then
                                    remCnt = remCnt + 1
                                end
                            end
                            for _, e in pairs(reach.near) do
                                if valid(e.actor) and not (game.isDead and game.isDead(e.actor)) then
                                    local ec = enemyClass(e.actor)
                                    if ec == q.class and e.loc and gap3d(refLoc, e.loc) <= 5500 then
                                        locCnt = locCnt + 1
                                    end
                                end
                            end
                            if locCnt + (spawnedByClass[q.class] or 0) < remCnt then
                            local actor = game.spawnByClass(q.cpath, sx, sy, sz, syaw)
                            if valid(actor) then
                                spawnedByClass[q.class] = (spawnedByClass[q.class] or 0) + 1
                                local addr = actor:GetAddress()
                                local fname = select(2, pcall(function() return actor:GetFName():ToString() end))
                                if game.markTwin then
                                    game.markTwin(addr, name, fname)
                                end
                                reach.near[addr] = { actor = actor, loc = { X = sx, Y = sy, Z = sz }, addr = addr }
                                net.dynSpawned[name] = { actor = actor, addr = addr, fname = fname, seenAt = now }
                                end
                            end
                        end
                    end
                end
            end
            -- Prune orphaned or far-away DYN copies (prevents sky-arena puppets from dropping onto the grass bell!)
            for name, rec in pairs(net.dynSpawned or {}) do
                if not valid(rec.actor) or (game.isDead and game.isDead(rec.actor)) then
                    if rec.addr and game.forgetTwin then game.forgetTwin(rec.addr) end
                    net.dynSpawned[name] = nil
                else
                    if net.remoteEnemies[name] ~= nil then
                        rec.seenAt = now
                    end
                    local okL, l = pcall(function() return rec.actor:K2_GetActorLocation() end)
                    local far = okL and l and gap3d(refLoc, l) > 5500
                    if far or now - (rec.seenAt or now) > 4.0 then
                        if rec.addr and game.forgetTwin then game.forgetTwin(rec.addr) end
                        pcall(function() rec.actor:K2_DestroyActor() end)
                        net.dynSpawned[name] = nil
                    end
                end
            end
            -- Auto-prune excess unmatched For<Boss>* puppets so Guest always matches Host's exact enemy count
            if now >= (net.excessPruneAt or 0) and linked() and next(net.remoteEnemies) ~= nil
                and os.clock() - (net.lastRemoteAt or 0) <= 2.0 then
                net.excessPruneAt = now + 1.0
                net.excessSeen = net.excessSeen or {}
                local matchedAddrs = {}
                for id, a in pairs(enemyByName) do
                    if net.remoteEnemies[id] ~= nil and valid(a) then
                        matchedAddrs[a:GetAddress()] = true
                    end
                end
                local remByCls = {}
                for _, r in pairs(net.remoteEnemies) do
                    if r.Class and (r.Hp or 0) > 0 and r.X and gap3d(net.localLoc, r) <= 5500 then
                        remByCls[r.Class] = (remByCls[r.Class] or 0) + 1
                    end
                end
                local locTotal, unmatchedByCls, seenNow = {}, {}, {}
                for addr, e in pairs(reach.near) do
                    if valid(e.actor) and not (game.isDead and game.isDead(e.actor)) and e.loc
                        and gap3d(net.localLoc, e.loc) <= 5500 then
                        local ec = enemyClass(e.actor)
                        if type(ec) == "string" and ec:find("^BP_Monster_") and net.dynClassOK(ec)
                            and not ec:find("StuntDouble", 1, true) then
                            local eid = game.enemyId and game.enemyId(e.actor, addr) or ""
                            if eid:sub(1, 3) ~= "sp:" then
                                locTotal[ec] = (locTotal[ec] or 0) + 1
                                if not matchedAddrs[addr] then
                                    seenNow[addr] = true
                                    net.excessSeen[addr] = net.excessSeen[addr] or now
                                    local list = unmatchedByCls[ec]
                                    if not list then
                                        list = {}
                                        unmatchedByCls[ec] = list
                                    end
                                    list[#list + 1] = { addr = addr, actor = e.actor, since = net.excessSeen[addr] }
                                end
                            end
                        end
                    end
                end
                for addr in pairs(net.excessSeen) do
                    if not seenNow[addr] then
                        net.excessSeen[addr] = nil
                    end
                end
                for ec, total in pairs(locTotal) do
                    local want = remByCls[ec] or 0
                    local over = total - want
                    if over > 0 and unmatchedByCls[ec] then
                        for _, u in ipairs(unmatchedByCls[ec]) do
                            if over <= 0 then
                                break
                            end
                            if now - u.since >= 2.0 then
                                if game.forgetTwin then game.forgetTwin(u.addr) end
                                reach.near[u.addr] = nil
                                net.excessSeen[u.addr] = nil
                                for dn, rec in pairs(net.dynSpawned or {}) do
                                    if rec.addr == u.addr then
                                        net.dynSpawned[dn] = nil
                                        break
                                    end
                                end
                                pcall(function() u.actor:K2_DestroyActor() end)
                                over = over - 1
                            end
                        end
                    end
                end
            end
        end
        -- 2. Prune timed-out remote visual Ctrl summons
        for key, s in pairs(net.remoteSummons) do
            if not valid(s.actor) or now - s.at > 4.0 then
                if s.addr and game.visualSummons then game.visualSummons[s.addr] = nil end
                if valid(s.actor) then
                    pcall(function() s.actor:K2_DestroyActor() end)
                end
                net.remoteSummons[key] = nil
            else
                if game.stopAI then
                    s.brain = game.stopAI(s.actor, s.brain)
                end
                if game.setupVisualSummon and not s.rechecked then
                    s.rechecked = true
                    game.setupVisualSummon(s.actor)
                end
            end
        end
        if dead then
            return
        end
        local remoteAddrs = {}
        for _, s in pairs(net.remoteSummons) do
            if s.addr then remoteAddrs[s.addr] = true end
        end
        local live = {}
        for _, ch in ipairs(FindAllOf("PBZCharacter_NPC") or {}) do
            if valid(ch) then
                local addr = ch:GetAddress()
                if not remoteAddrs[addr] and game.isPlayerSummon(ch) and not (game.isDead and game.isDead(ch)) then
                    local uid = tostring(addr)
                    live[uid] = ch
                    if not net.ownSummons[uid] then
                        local okL, l = pcall(function() return ch:K2_GetActorLocation() end)
                        local okR, r = pcall(function() return ch:K2_GetActorRotation() end)
                        local cpath = okL and l and game.classPathOf(ch)
                        if cpath and cpath:find("^/") then
                            local yaw = (okR and r and r.Yaw) or 0
                            net.ownSummons[uid] = ch
                            sendEvent("PSUM", uid, cpath, string.format("%.0f %.0f %.0f %.0f", l.X, l.Y, l.Z, yaw))
                        end
                    else
                        net.ownSummons[uid] = ch
                    end
                end
            end
        end
        for uid in pairs(net.ownSummons) do
            if not live[uid] then
                net.ownSummons[uid] = nil
                sendEvent("PSUMEND", uid)
            end
        end
        if next(net.ownSummons) ~= nil and game.noteLocalMove then
            game.noteLocalMove()
        end
    end

    extraTicksEarly.noPause = function()
        if linked() then
            local controller, pawn = getPlayer1()
            if valid(pawn) and api.gs():IsGamePaused(controller) then
                api.gs():SetGamePaused(controller, false)
            end
        end
    end

    handlers.BEATEN = function(name, from)
        if from ~= nil then
            return          -- (the host's word only: another guest's, passed on by the relay, is no host's)
        end
        if not isClient() or type(name) ~= "string" or #name > MAX_ITEM_NAME then
            return
        end
        log("The host has beaten " .. name .. ": beaten here too.")
        net.hostBosses[name] = true        -- (so that the kill below ends the fight here: bar down, walls open)
        handlers.K(name, nil, true)
    end

    handlers.B = function(name, from)
        -- (Not one that fell here a moment ago: see net.fellLately. Up again, its record is alive again: game.unmarkBeaten.)
        if isHost() and game.isBeaten and game.isBeaten(name) and not net.fellLately(name) then
            tellBeaten(name, nil)       -- (to everyone: the relay gave the other guests this fight too)
            return
        end
        -- (Told again, by the same player, and shown here already: a newcomer's J has every fighter tell their fight.)
        if net.partnerBosses[name] and (not net.party or net.fightOf[name] == (from or 1)) then
            return
        end
        -- (Host: a fight this game has started itself, its own bar up on that boss, stays this game's own. Two players
        -- whose scenes end together each tell their start in the same moment (398 makes that the common case: the
        -- bench, 11-19, run225, the two starts 0.8 ms apart), and filed here as the guest's, the host's own fight was
        -- nobody's: that guest's F 0 takes the host's bar down and opens its walls mid-fight, and a guest's rest
        -- refreshes the host's world (announceBoss, where the same is put right for a guest who began first).)
        if isHost() then
            local own = enemyByName[name]
            if valid(own) and not game.isDead(own) and game.bossAt and game.bossAt(own:GetAddress(), own)
                and not (game.isMirrorBar and game.isMirrorBar(own)) then
                net.bossesSeen = net.bossesSeen or {}
                net.bossesSeen[name] = true     -- (any sit puts it back to full health: net.sitBossesToFull)
                log("The other player started a boss fight with " .. name .. " as this game did: it stays this game's own.")
                return
            end
        end
        -- (Guest: another guest's word of a fight this world has as the host's, or has begun itself, isn't that
        -- guest's. Three whose scenes end together each tell their start, the host's word first here (another guest's
        -- comes through the host's relay): filed as that guest's, their drop or their F 0 took this player's bar down
        -- and opened its walls mid-fight, the host and this player still in it. 402, for a guest: the review of 401.)
        if isClient() and from ~= nil then
            local own = enemyByName[name]
            if (net.partnerBosses[name] and net.fightOf[name] == 1) or (valid(own) and not game.isDead(own)
                and game.bossAt and game.bossAt(own:GetAddress(), own) and not (game.isMirrorBar and game.isMirrorBar(own))) then
                return
            end
        end
        log("The other player started a boss fight with " .. name .. ".")
        -- (The host's word only. Another guest's fight, passed on by the relay, isn't the host's: taken for it, it stayed
        -- the host's fight here for good, and came back as walls and a bar after this player's next death.)
        local fromHost = net.role == "client" and from == nil
        if fromHost then
            -- The host has it alive and is fighting it, whatever this session last heard (their world loaded again, say): a copy
            -- brought back for the fight would be killed on sight as the host's old kill.
            net.hostKilled[name] = nil
            net.pendingDeaths[name] = nil
        end
        net.partnerBosses[name] = true
        if isHost() then
            net.bossesSeen = net.bossesSeen or {}
            net.bossesSeen[name] = true     -- (any sit puts it back to full health, the fight over or not: net.sitBossesToFull)
        end
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
        if net.arena then
            return              -- (an arena's boss, parked for a PvP match: no fight to tell anyone of)
        end
        local addr, name = actor:GetAddress(), enemyName(actor)
        for id, e in pairs(enemyByName) do
            if valid(e) and e:GetAddress() == addr then
                name = id
                break
            end
        end
        -- (Not known by its spawner yet, just spawned: the ids are read again first. Told by its actor name, the other
        -- player's game had no such enemy and never showed the fight: AHua on the bench.)
        if not name:find("^sp:") and game.refreshEnemyIds then
            game.refreshEnemyIds(true)
            name = enemyName(actor, addr)
        end
        if isClient() and net.hostKilled[name] then
            -- (Unless it fell in a fight a moment ago: a boss that gets up again in it (Xiaoxue), raised here by this world's
            -- own script. Killed quietly 0.1 s on and written beaten, it vanished for the guest, and only the host's world
            -- gave the story's reward. It's the host's fight again here, as bring.missing makes it.)
            local fell = net.bossFell and net.bossFell[name]
            if fell and (net.frameNow or link.now()) - fell < net.FALL_GRACE_S then
                net.hostKilled[name], net.pendingDeaths[name] = nil, nil
                local hostFights = net.party and peerOf(nil).fights or (not net.party and net.partnerFighting)
                if hostFights then
                    net.partnerBosses[name], net.hostBosses[name], net.pendingBosses[name] = true, true, true
                    if net.party then
                        net.fightOf[name] = 1
                    end
                end
                log("Boss " .. name .. " is up again here after its fall: the host's fight again, not killed.")
                return
            end
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
        -- (A party guest's copy of one asleep on the host that this game doesn't run: the game's own bar on it is the stray
        -- of an AI started for a moment, no fight of this player's (net.fightingHere). Told, it filed the fight as theirs
        -- everywhere, ahead of the fighter's own, whose lost fight then never started over: the next try began where the
        -- last ended, and the walls stayed shut for a fight nobody was in. One that's theirs after all is told as
        -- handover.byHere makes the copy this game's. The third review.)
        if net.party and isClient() and handover.live[addr] == nil and (net.remoteEnemies[name] or {}).Asleep == true then
            return
        end
        -- (On the host, a bar the game put up itself is this game's own fight, whatever actor it's on: the host's own scene
        -- brought a new actor of the boss a guest had started first, and the fight stayed filed as the guest's. That guest's F 0
        -- then took the host's bar down and opened its walls mid-fight, and a guest's bell rest refreshed the host's world.)
        if isHost() and net.partnerBosses[name] then
            net.partnerBosses[name], net.fightOf[name] = nil, nil
            if net.joinedBoss == name then
                net.joinedBoss, net.joinedWith, net.joinedFar = nil, nil, nil
            end
            log("Boss fight with " .. name .. ": this game's own now, not only the other player's.")
        end
        if not net.partnerBosses[name] then
            sendEvent("B", name)
            net.fightRetellAt = os.clock() + 4.0        -- (a bar that only blinked: tellFight)
            net.bossesTold = net.bossesTold or {}
            net.bossesTold[name] = true     -- (any sit puts it back to full health, this player down or not: net.sitBossesToFull)
            if isClient() then
                net.hostBosses[name] = true    -- the host fights it too from now on
                net.ownAnnounced = net.ownAnnounced or {}
                net.ownAnnounced[name] = true
            end
        end
    end

    -- The host's game started its own fight with a boss it was showing for a guest's: the host's fight from now on, told to
    -- everyone (B), and a guest's F no longer ends it. (On a guest, a fight on the host's boss stays the host's.)
    function net.ownFightOn(boss)
        if isClient() or not valid(boss) then
            return
        end
        local addr, name = boss:GetAddress(), enemyName(boss)
        for id, e in pairs(enemyByName) do
            if valid(e) and e:GetAddress() == addr then
                name = id
                break
            end
        end
        if net.partnerBosses[name] then
            net.partnerBosses[name], net.fightOf[name] = nil, nil
            if net.joinedBoss == name then
                net.joinedBoss, net.joinedWith, net.joinedFar = nil, nil, nil     -- (its own now: no trip back after it)
            end
            log("Boss fight with " .. name .. ": this game's own now, not only the other player's.")
        end
        announceBoss(boss)
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
        local x, y, z, yaw, vx, vy, vz, mode, hp, maxhp = game.read(pawn, slow.pawn)
        -- Occasionally a read comes back incomplete (seen in PBZ while walking); skip that frame. Same for NaN
        -- (x ~= x), which would send the ghost into nowhere.
        if x == nil or y == nil or z == nil or yaw == nil or x ~= x or y ~= y or z ~= z or yaw ~= yaw then
            return
        end
        if vx ~= vx then
            vx, vy, vz = 0, 0, 0
        end
        local flags = slow.cine * 2 + (net.moveBits or 0)      -- (and how they move, their guard stance: moves.lua)
        if mode == MOVE_WALKING then
            flags = flags + 1
        elseif mode == MOVE_FALLING then
            flags = flags + 4
        elseif mode ~= MOVE_NONE then
            flags = flags + 8       -- ladders, wall runs and the like fly the player along their montage
        end
        -- (A jump of more than 30 m, a trip on the same map that didn't stall: this world is still streaming in, and gives no
        -- "no" a while (HAS). A stall is caught in tick.)
        local was = net.localLoc
        if was and (x - was.X) ^ 2 + (y - was.Y) ^ 2 > 3000 * 3000 then
            net.unsettledUntil = math.max(net.unsettledUntil or 0, os.clock() + net.UNSETTLED_S)
        end
        net.localLoc = { X = x, Y = y, Z = z }
        -- Health from the same read, with the place: a hit shows on the partner's screen the frame after, not on the next
        -- of watchSlowly's ten reads a second.
        if hp and maxhp and hp == hp and maxhp > 0 then
            slow.hp, slow.maxhp, slow.hpAt = hp, maxhp, net.frameNow
        end
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

    -- A hit reaction of the local player's goes out in the frame it starts (see game.watchHitState).
    frameTicks.hitState = function()
        local pawn = game.watchHitState and localPawn()
        if pawn then
            game.watchHitState(pawn, sendEvent)
        end
    end

    frameTicks.execLock = function(force)
        if not (net.enabled and game.hitStateOf and game.execLock) then
            return
        end
        local now = os.clock()
        if not force and now < (net.exLockNextAt or 0) then
            return
        end
        net.exLockNextAt = now + 0.12
        for name, exp in pairs(net.partnerExec) do
            local actor = enemyByName[name]
            if now >= exp or not valid(actor) or (game.isDead and game.isDead(actor)) then
                net.partnerExec[name] = nil
                if valid(actor) then
                    game.execLock(actor, false)
                end
            end
        end
        for name, rec in pairs(net.ownExec) do
            local actor = enemyByName[name]
            if not valid(actor) or (game.isDead and game.isDead(actor)) or now - rec.at >= net.EXEC_LOCK_S then
                net.ownExec[name] = nil
                sendEvent("EX", name, "0")
            end
        end
        local pawn = localPawn()
        if not valid(pawn) or (game.isDead and game.isDead(pawn)) then
            return
        end
        local pl = pawn:K2_GetActorLocation()
        local playerExecTarget = nil
        if api.moves then
            local pai = api.moves.animOf(pawn)
            local pm = pai and pai:GetCurrentActiveMontage()
            if valid(pm) then
                local pn = (pm:GetFName():ToString() or ""):lower()
                if net.isExecName(pn) then
                    local bestD = 450
                    for name, actor in pairs(enemyByName) do
                        if valid(actor) and not (game.isDead and game.isDead(actor)) and not net.partnerExec[name] then
                            local okL, el = pcall(function() return actor:K2_GetActorLocation() end)
                            if okL and el then
                                local d = gap3d(pl, el)
                                if d < bestD then
                                    bestD, playerExecTarget = d, name
                                end
                            end
                        end
                    end
                end
            end
        end
        for name, actor in pairs(enemyByName) do
            if valid(actor) and not (game.isDead and game.isDead(actor)) then
                local okL, el = pcall(function() return actor:K2_GetActorLocation() end)
                if okL and el and gap3d(pl, el) <= 800 then
                    local addr = actor:GetAddress()
                    local isBoss = (game.isBoss and game.isBoss(actor, addr)) or (game.bossTwin and game.bossTwin(actor, addr))
                    local st = game.hitStateOf(actor)
                    if isBoss and st and st ~= "None" and now - (net.parrySharedAt[name] or 0) > 1.5 then
                        local sl = st:lower()
                        -- (Not "guard", "weak", "stagger" or any "break": a boss merely guarding was sent
                        -- as a parry and frozen in the partner's world.)
                        if sl:find("parried", 1, true) or sl:find("beparry", 1, true) or sl:find("deflected", 1, true)
                            or sl:find("poisebreak", 1, true) or sl:find("posturebreak", 1, true) then
                            net.parrySharedAt[name] = now
                            sendEvent("PARRY", name, st)
                        end
                    end
                    if now - (tonumber(net.shieldSent[name]) or -1e9) > 8.0 and game.isShieldBroken and game.isShieldBroken(actor) then
                        net.shieldSent[name] = now      -- (Bosses too, and again once the shield is back)
                        sendEvent("SHLD", name)
                    end
                    if not net.partnerExec[name] then
                        local isExec = (st ~= nil and st:find("Executing", 1, true) ~= nil) or (playerExecTarget == name)
                        local rec = net.ownExec[name]
                        if isExec then
                            local mpath, mpos = "-", 0
                            if api.moves then
                                local ai = api.moves.animOf(actor)
                                local m = ai and ai:GetCurrentActiveMontage()
                                if valid(m) then
                                    local p = api.moves.pathOf(m)
                                    if api.moves.allowedPath(p) then
                                        mpath, mpos = p, ai:Montage_GetPosition(m) or 0
                                    end
                                end
                            end
                            if not rec or (rec.mpath == "-" and mpath ~= "-") then
                                local yaw = 0
                                pcall(function() yaw = actor:K2_GetActorRotation().Yaw end)
                                net.ownExec[name] = { at = rec and rec.at or now, addr = addr, mpath = mpath }
                                sendEvent("EX", name, "1", string.format("%.1f", el.X), string.format("%.1f", el.Y),
                                    string.format("%.1f", el.Z), string.format("%.1f", yaw), mpath, string.format("%.2f", mpos))
                            end
                        elseif rec then
                            net.ownExec[name] = nil
                            sendEvent("EX", name, "0")
                        end
                    end
                end
            end
        end
    end

    -- (Shields and protections (game.MIRROR_EFFECTS, exact names) kept the same in both worlds. Twice a
    -- second the game that runs an enemy near its player looks at them; one gone is told, and the other game takes the
    -- same one off its copy. net.MIRROR_EFFECTS_ON = false turns it off.)
    net.MIRROR_EFFECTS_ON, net.geSeen, net.geLookAt = true, {}, 0
    frameTicks.geMirror = function()
        if not (net.enabled and net.MIRROR_EFFECTS_ON ~= false and game.mirrorEffectsOf and linked()) then
            return
        end
        local now = os.clock()
        if now < net.geLookAt then
            return
        end
        net.geLookAt = now + 0.5
        local origin = net.localLoc
        if not origin then
            return
        end
        local host, looked = isHost(), 0
        for name, actor in pairs(enemyByName) do
            if looked >= 12 then
                break
            end
            local runsHere = (host and not net.guestRuns[name]) or (not host and net.mine[name])
            if runsHere and valid(actor) and not (game.isDead and game.isDead(actor)) then
                local okL, at = pcall(function() return actor:K2_GetActorLocation() end)
                if okL and at and gap3d(origin, at) <= 4000 then
                    looked = looked + 1
                    local nowSet, before = game.mirrorEffectsOf(actor), net.geSeen[name]
                    if before then
                        for ge in pairs(before) do
                            if not nowSet[ge] then
                                sendEvent("GEOFF", name, ge)
                                log("Shield/protection " .. ge .. " left " .. name .. ": told the other player.")
                            end
                        end
                    end
                    net.geSeen[name] = nowSet
                end
            end
        end
    end
    handlers.GEOFF = function(rest, from)
        local name, ge = (rest or ""):match("^(%S+) (%S+)$")
        if not (name and ge and game.removeEffectNamed) then
            return
        end
        local actor = enemyByName[name]
        if valid(actor) and not (game.isDead and game.isDead(actor)) then
            local n = game.removeEffectNamed(actor, ge)
            if n > 0 then
                log("The other player's " .. name .. " lost " .. ge .. ": taken off here too.")
            end
        end
    end

    -- Frame-0 trigger called by moves.lua the instant the local player starts an execution montage.
    net.onLocalExecStart = function()
        frameTicks.execLock(true)
    end

    -- pbz.lua's cameras, every frame while one runs: the finishing move's (game.cinemaTick) and the downed player's watch
    -- (game.spectateTick). A key of its own made here at load: made as one started, from a stage inside the frame loop, it
    -- was a new key in the middle of that loop's traversal, which Lua leaves undefined (the review of 1.7.0).
    frameTicks.cameras = function()
        local cinema, spectate = game.cinemaTick, game.spectateTick
        if cinema then
            cinema()
        end
        if spectate then
            spectate()
        end
    end

    -- Everything about the local player that doesn't need to go out every frame.
    local function watchSlowly(now)
        local pawn = localPawn()
        if pawn == nil then
            game.watchPickupCard(nil)
            return
        end
        if game.getHealth and slow.hpAt ~= net.frameNow then       -- (only when this frame's read had none: sendPlayer)
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
                net.livedAt, net.livedAs, net.metDeadAt, net.metDeadAs = {}, {}, {}, {}
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
        -- (The player's moves as abilities, for PvP, are read every frame in arena.lua's frameMoves, in a match and in PvPvE:
        -- here, ten times a second, a guard tapped up read as one held from before, and a parry was lost; the review.)
        -- (Not in the quiet after a load or a trip: see net.QUIET_AFTER_LOAD_S. A host crashed in here, in its first frame
        -- after a trip on the same map.)
        local quiet = os.clock() < (net.quietUntil or 0)
        if game.watchItemFx and now >= (slow.itemFxAt or 0) and not quiet then
            slow.itemFxAt = now + SLOW_S
            -- A drink from the gourd draws the eye of the host's enemies near this player (game.steerTarget).
            if game.watchItemFx(pawn, sendEvent) and not net.pvp then
                if isHost() then
                    game.playerHealed(net.slot or 1)
                else
                    sendEvent("HEAL")
                end
            end
        end
        -- (The game takes the bars down for a cutscene: put back at once, they'd flicker through it.)
        if next(net.partnerBosses) and game.keepBossBar and now >= (slow.barsAt or 0) and not quiet and not net.arena
            and not game.inCutscene() then
            slow.barsAt = now + BOSS_BAR_S
            for name in pairs(net.partnerBosses) do
                local boss = enemyByName[name]
                if valid(boss) and not game.isDead(boss) then
                    -- (Paired since with another copy of that boss, the one this world's own scene brought in: the bar on the
                    -- one before comes down. Left, it stood there full and frozen beside this one's; a report on 1.6.9.)
                    local shown = net.mirrorOn and net.mirrorOn[name]
                    if shown and shown.addr ~= boss:GetAddress() then
                        if valid(shown.actor) and shown.actor:GetAddress() == shown.addr
                            and select(2, pcall(function() return shown.actor:GetFName():ToString() end)) == shown.fname
                            and game.isMirrorBar and game.isMirrorBar(shown.actor) and game.hideBossBar then
                            game.hideBossBar(shown.actor)
                        end
                        net.mirrorOn[name] = { actor = boss, addr = boss:GetAddress(),
                            fname = select(2, pcall(function() return boss:GetFName():ToString() end)) }
                    end
                    game.keepBossBar(boss)      -- (the game's own bar on it is left alone there: pbz.lua)
                    -- (One the game hasn't started in this world, a figure on the player's own side: no blow landed
                    -- on it, none of its own on this player. pbz.lua's game.enemySide. Normally this is a guest's copy.
                    -- The guest-driven Dragon Pillar fight also needs this on the host's mirror while it follows.
                    -- On a guest, only one that follows the host's
                    -- fight: a party guest's own copy of another guest's fight follows no moves, and on the
                    -- enemy's side it was a figure that never fought back, whose death was the boss's everywhere.
                    -- And only while that fight is told as on there, as stillFought has it: a bar that only
                    -- blinked there tells none, and blows here till 344's end went to a figure in no fight there.)
                    local fromHost = isClient() and net.hostBosses[name]
                    local dragonMirror = handover.dragonPillarFight(name) and game.isMirrorBar and game.isMirrorBar(boss)
                    local fromGuest = not net.party and isHost() and dragonMirror and net.guestRuns[name]
                    if (fromHost or fromGuest) and game.enemySide and api.puppets and api.puppets.follows(boss:GetAddress())
                        and (net.party and peerOf(net.fightOf[name] or 1).fights or (not net.party and net.partnerFighting))
                        and game.enemySide(boss, dragonMirror) == "put" then
                        log(name .. " isn't started in this world: on the enemy's side while the other player's fight with it lasts.")
                    end
                end
            end
        end
        -- (Never both in a frame: each looks through every actor of a kind.)
        if quiet or net.arena then
            -- (nothing: the searches wait; in a PvP match nothing of the world's is told)
        elseif game.watchPickups and now >= (slow.pickupsAt or 0) then
            if game.watchPickups(pawn, reportPickup) ~= false then
                slow.pickupsAt = now + PICKUP_S
            end
        elseif game.watchChests and (now >= (slow.chestsAt or 0) or net.chestsSoon) then
            slow.chestsAt, net.chestsSoon = now + PICKUP_S, nil
            game.guardFormations()
            game.hookGifts(sendGift)
            game.hookPiles(reportChest)
            if game.hookFlowers then
                game.hookFlowers(net.reportFlower)
            end
            game.watchChests(pawn, reportChest, isHost() and offerChest or nil)
            if game.watchStones then
                game.watchStones(pawn, function(name, at, rot)
                    log("Kicked " .. name .. " away: telling the other player where it lies.")
                    sendEvent("KS", name, string.format("%.1f %.1f %.1f %.2f %.2f %.2f", at.X, at.Y, at.Z, rot.Pitch, rot.Yaw, rot.Roll))
                end)
            end
        elseif game.watchFlowers and next(game.flowers.owed) ~= nil and (now >= (slow.flowersAt or 0) or net.flowersSoon) then
            -- (A Memory Flower another player picked: our copy gone once its petal is here, or as it loads. pbz.lua.)
            if game.watchFlowers(pawn) ~= false then
                net.flowersSoon = nil
                slow.flowersAt = now + (game.flowers.nextS or game.flowers.LOOK_S)
            end
        end
        if (#giftsWaiting > 0 or dustWaiting > 0) and not game.isDead(pawn) and not net.arena then
            takeGifts(pawn)
        end
        -- (What came shows on the right, the game's own notice for a find; a partner's pickup whose share never came is
        -- given from our copy of it: pbz.lua.)
        if game.pickupShares and #game.pickupShares > 0 and not game.isDead(pawn) and not net.arena then
            game.pickupSharesDue(pawn)
        end
        game.watchPickupCard(not quiet and cine == 0 and slow.hp > 0 and not net.arena and pawn or nil)
        if game.tipsWanted and not quiet and cine == 0 and not game.isDead(pawn) and not net.arena then
            game.showPickupTips(pawn)       -- (a card waiting from before isn't put up in a PvP match)
        end
        if game.watchGear and now >= (slow.gearAt or 0) and not net.arena then
            slow.gearAt = now + GEAR_S
            game.watchGear(pawn, sendGift)
        end
        -- What this player wears, to the others: when it changes, and to someone who starts sync or joins (S, J). (Not every
        -- half minute too: the sure lane brings it, and a ghost made later is dressed from what was heard, p.look.)
        if game.ownLook and now >= (slow.lookAt or 0) then
            slow.lookAt = now + 1.0
            local outfit, hidden, skin = game.ownLook(pawn)
            local line = outfit and string.format("%s %d %d", outfit, hidden and 1 or 0, skin)
            if line and line ~= net.lookSent then
                net.lookSent = line
                sendEvent("LOOK", line)
            end
        end
        if game.watchCurrency and now >= (slow.dustAt or 0) and not net.arena then
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
        -- (Or heard steadily well after it: a trip on the same map can be silent under 3 s, and its minute ran on, a real
        -- drop after it noticed in 60 s, not 12.)
        local loadEnded = false
        if p.loadingUntil and p.lastRemoteAt and (heardAt - p.lastRemoteAt >= 3
            or (p.loadToldAt and heardAt - p.loadToldAt > 8)) then
            p.loadingUntil, p.loadToldAt = nil, nil
            loadEnded = true
        end
        if p.byeAt and heardAt > p.byeAt + 1 then
            p.byeAt = nil           -- (their sync is on again: see BYE)
        end
        -- (The host back from a load, or more than 30 m from where it was (a trip, a bell, a respawn): its world is still
        -- streaming in, and its "not in my world" of an enemy it hadn't spawned yet hid that enemy here for good (report 3:
        -- "small enemies go invisible; teleporting to the player or sitting at a bell sets it off"). No new asks for a while:
        -- see setAside. Any host's, one on 1.6.6 too.)
        local t0 = p.target
        if p == net and isClient() and (loadEnded or (t0 and t0.X and (x - t0.X) ^ 2 + (y - t0.Y) ^ 2 > 3000 * 3000)) then
            net.hostSettleUntil = clock + net.UNSETTLED_S
        end
        if p.lastRemoteAt and heardAt - p.lastRemoteAt > net.GAP_KILL_AFTER_S then
            p.backAt, p.gapFrom = clock, p.lastRemoteAt     -- (back after a gap, and when it began: net.gapKill, net.gapOld)
        end
        p.lastRemoteAt = heardAt
        local t = p.target or {}
        t.X, t.Y, t.Z, t.Yaw, t.VX, t.VY, t.VZ = x, y, z, yaw, vx, vy, vz
        t.Hp, t.MaxHp = hp, maxhp
        t.Map = map ~= 0 and map or nil
        t.Grounded, t.Cine, t.Falling, t.Climbing = flags & 1 ~= 0, flags & 2 ~= 0, flags & 4 ~= 0, flags & 8 ~= 0
        p.target = t
        -- How they move and whether they hold the guard stance, in step with this place (moves.lua). Neither said: an older
        -- version, which tells them by events.
        if flags & 0x30 ~= 0 and net.heardMoveBits then
            net.heardMoveBits(p, flags)
        end
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
        net.livedAt, net.livedAs, net.metDeadAt, net.metDeadAs = {}, {}, {}, {}
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
        net.joinedBoss, net.joinedWith, net.farFight, net.bossOverAt, net.lastFarFight = nil, nil, nil, nil, nil
        net.healTicks = {}
        net.lethalPending, net.ownExec, net.partnerExec, net.parrySharedAt = {}, {}, {}, {}
        if net.clearDynSpawned then net.clearDynSpawned() end
        net.dynSent, net.dynTried, net.dynPending, net.shieldSent, net.classCache, net.ownSummons = {}, {}, {}, {}, {}, {}
        for _, s in pairs(net.remoteSummons or {}) do
            if s.addr and game.visualSummons then game.visualSummons[s.addr] = nil end
            if valid(s.actor) then pcall(function() s.actor:K2_DestroyActor() end) end
        end
        net.remoteSummons = {}
        net.capped = {}
        net.bossFell, net.extraBossWatch, net.watchGaveUp, net.watchHeldAt = {}, {}, nil, nil
        net.fellInFight = {}
        net.postureTicks, net.postureFull = {}, {}
        net.hostSeen = {}
        net.partnerDowned = false
        enemyByName = {}
        seen = {}
        round.queue, round.at, round.seen, round.held = {}, 1, nil, nil
        reach.near = {}
    end

    local function destroyGhost(p)
        if valid(p.ghost) then
            -- A clone (this player's own class) isn't destroyed mid-world: put away, hidden, frozen far up and off every list,
            -- and gone with the next load, as the world takes everything then. Players reported locked slots their talent tree
            -- had opened, every time someone left, fixed only by resetting the tree: the clone's end of life (its unbinding
            -- from the world's skill and backpack systems, which it shares with this player) is the one thing a leave does.
            -- (Whether it's one was decided as it was made: asked here with no body of this player's own (a load, a death,
            -- getPlayer1's pawn gone), it read as not one, and the clone was destroyed after all.)
            local clone = p.ghostClone
            if clone == nil then
                local ok, same = pcall(function()
                    local _, pawn = getPlayer1()
                    return valid(pawn) and p.ghost:GetClass():GetAddress() == pawn:GetClass():GetAddress()
                end)
                clone = ok and same
            end
            if clone then
                -- (Not left following one put away 2 km up: a downed player watching it saw the sky till respawn.)
                if game.spectatingAt and game.spectatingAt() == p.ghost:GetAddress() then
                    game.spectate(nil)
                end
                -- Kept by address and name for the next ghost of this class to take back (spawnGhost): one made each time
                -- piled up, a full player body each, five more with each hiccup of a 6-player party.
                net.parkedClones = net.parkedClones or {}
                pcall(function()
                    table.insert(net.parkedClones, { addr = p.ghost:GetAddress(), fname = p.ghost:GetFName():ToString(),
                        class = p.ghost:GetClass():GetFName():ToString() })
                end)
                pcall(function()
                    if game.ghostInFight then
                        game.ghostInFight(p.ghost, false, game.listEnemies() or {})     -- (off every enemy's list)
                    end
                    p.ghost:SetActorHiddenInGame(true)
                    p.ghost:SetActorEnableCollision(false)
                    p.ghost.CharacterMovement:SetMovementMode(MOVE_NONE, 0)
                    local l = p.ghost:K2_GetActorLocation()
                    p.ghost:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z + 200000 }, false, {}, true)
                    p.ghost:SetActorTickEnabled(false)
                end)
            else
                p.ghost:K2_DestroyActor()
            end
        end
        -- (Its address is free now: left marked as a ghost's, an enemy given it later was never shared nor synced.)
        if p.ghostAddr then
            net.ghostSlots[p.ghostAddr] = nil
            p.ghostAddr = nil
        end
        p.ghost = nil
        p.ghostCmc = nil
        p.ghostHidden, p.ghostSolid = nil, nil
        p.ghostGliding = false
        p.ghostClone = nil
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
            api.status.notify("pvp", "PvPvE is off with more than two players (F6 PvP has teams).")
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
        if link.other then
            log("Online sync can't start: main.dll is another version's (" .. tostring(link.other) .. "). Close the game, extract the Phantom Pact zip again, then start the game.")
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
        peerOf(from).loadToldAt = os.clock()
    end
    function net.tellLoading()
        if net.enabled then
            pcall(sendEvent, "LOAD")
        end
    end
    pcall(function()
        -- (And this world settles: a host's bell trip on the same map said "not here" of enemies still streaming in.)
        RegisterHook("/Script/ProjectPBZ.PBZSaveLoadSubsystem:TeleportTo", function()
            net.tellLoading()
            pcall(net.unsettle)
            if game.forgetActors then
                pcall(game.forgetActors)        -- (spawners stream in on freed addresses: their ids read afresh)
            end
        end)
    end)

    -- The first seconds after a map's load: the world searches (FindAllOf) of the slower jobs still hand back the old map's
    -- actors being torn down, and touching one crashed the game inside UE4SS, where no pcall catches it (three times on the
    -- bench, each just after a trip; the trace named the chains-and-levers job). They wait till it's over.
    net.QUIET_AFTER_LOAD_S = 5
    net.SETTLE_S = 30               -- (how long after a load a hitch still counts as loading in)
    net.OWED_AFTER_S = 15           -- (up this long after a respawn before a boss's pay owed is given: watchOwnDeath)
    pcall(function()
        RegisterLoadMapPostHook(function()
            net.quietUntil = os.clock() + net.QUIET_AFTER_LOAD_S
            net.settleUntil = os.clock() + net.SETTLE_S
        end)
    end)
    pcall(function()
        RegisterLoadMapPreHook(function()
            net.tellLoading()
            net.unsettledUntil = os.clock() + net.UNSETTLED_S + 20     -- (a load takes a while: no "no" given till settled)
            net.notOnHost, net.aside = {}, {}
            net.parkedClones = {}       -- (the world takes them with it)
            net.bossFell, net.extraBossWatch, net.lethalPending = {}, {}, {}     -- (this world's actors go with the load: nothing to bring back down)
            net.spawnedFor = {}
            -- Enemies this world brought back for the host go back to dead in it before it's saved and left: put back at the
            -- end of the session, they'd be put back in whatever world is loaded then.
            pcall(bring.putBackAll)
            -- (What a boss's death here adds is no longer looked at for a host who was down: what comes now is the trip's.)
            if api.flowsync then
                api.flowsync.downFlow = {}
            end
            -- With a player in the world this is a trip: the same world on another map, and a partner's fight goes on. Only a
            -- load from outside it (the title screen) is a world loaded anew.
            if valid(select(2, getPlayer1())) then
                return
            end
            hostWorld = os.time()
            -- (Nor is what that world adds a boss's win: one fallen in the last world let another save's flags and flow
            -- steps out, up to flowsync.lua's 1000 at once. The review of 11-16.)
            net.bossFellAt = nil
            -- (Put-backs still owed were that world's: in another save, or a new game, they'd kill an enemy it has alive.)
            if game.owed then
                game.owed.ids = {}
            end
            -- (So was a boss's pay owed to this player for a death there, and its win's steps: pbz.lua's payOwed, flowsync's DB.)
            game.owedBosses, game.downAt, game.owedNames = nil, nil, nil
            if api.flowsync then
                api.flowsync.owedFlow, api.flowsync.downFlow = {}, {}
            end
            -- A guest's world loaded anew: the host's kills are still kills, and its save may not have them all. As after
            -- this player's death, each is put down again as it loads (bring.pending): the host's re-tell after the load's
            -- silence passes over the deaths handled here before (handlers.K), and the copies back alive went unseen.
            if isClient() then
                for name in pairs(net.hostKilled) do
                    net.pendingDeaths[name] = true
                end
            end
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
        -- A PvP match ends with sync, everything put back (arena.lua; its timers run on their own): left running, it
        -- froze there, the save held off and the match's loadout on (the review of 1.7.0).
        if api.arena and api.arena.match and api.arena.quit then
            pcall(api.arena.quit, "co-op was turned off", false)
        end
        pcall(sendEvent, "BYE")
        net.enabled = false
        game.watchPickupCard(nil)
        net.partnerFighting, net.toldFighting = false, nil
        if game.setDownBody then game.setDownBody(select(2, getPlayer1()), false) end
        game.holdRespawn(nil, false)
        net.holdLooking, net.holdWanted, net.respawnHeld, net.deadSince, net.struck = false, false, false, nil, {}
        net.finisherSince, net.finisherSaySince, net.floorRefused = nil, nil, {}
        -- (And what a boss owed this player for a death while down: given in a session after, its share went to whoever
        -- was there then. pbz.lua's payOwed.)
        game.owedBosses, game.downAt, game.owedNames, net.downBossFell = nil, nil, nil, nil
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
        if api.moves and api.moves.dropAllProps then
            pcall(api.moves.dropAllProps)   -- (what a ghost held for a skill: a jar left in the air)
        end
        if api.rules and api.rules.release then
            pcall(api.rules.release)        -- (a guest's own rules back: its ticks end with sync)
        end
        if api.bullets and api.bullets.endAll then
            pcall(api.bullets.endAll)       -- (and copies of their effects that loop, with nothing left to end them)
        end
        leaveParty()
        endFights()
        reopenFog()
        api.revive.stop()
        game.forgetLink()
        game.forgetFocus()      -- (alone, every enemy that was steered picks for itself again: its own wait back)
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
        if api.trace and api.trace.on() then
            log("trace stage " .. stage)
        end
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
        -- (Not in a PvP match: the dead and the bosses are the world's news, which a match goes without. It waits for the
        -- end: a trip's loading screen is a gap, and the retell then sent every death since the start into the match.)
        if p.retellAt and os.clock() >= p.retellAt and not net.arena then
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
        net.lookSent = nil      -- (and what this player wears: told only when it changes, otherwise)
        -- (A guest's own fight too: B goes once, as it starts, and one who joined after never saw it, bar or walls.
        -- The host tells its own in its S handling.)
        if isClient() then
            for _, actor in ipairs(net.ownBosses()) do
                local name, addr = enemyName(actor), actor:GetAddress()
                for id, e in pairs(enemyByName) do
                    if valid(e) and e:GetAddress() == addr then
                        name = id
                    end
                end
                sendEvent("B", name)
            end
        end
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
        -- (Or no F 1 heard at all, with a fight of theirs shown here: a B held up while this player was cut off came after
        -- the fight was over, and with nothing to end it its bar stayed up for good.)
        -- (2: down in it, waiting for it. Their fight goes on here, though they're nobody to wait for.)
        local down = on == "2"
        if down and from == nil then
            net.hostDownAt = os.clock()     -- (the host down in its fight: what ends next is a loss, see putDownLeftBosses)
        end
        local theirs = false
        if on ~= "1" and not down and not was then
            local whose = net.party and (from or 1) or nil
            for name in pairs(net.partnerBosses) do
                theirs = theirs or whose == nil or net.fightOf[name] == whose
            end
        end
        -- (Not from a partner who's down while this player is still in that fight: their game takes the bar down as they die,
        -- and ending the fight here let their held respawn go, its R death putting the boss back at full health (the report
        -- "After my teammate died, he instantly respawned, and the boss's HP was restored to full" on 1.6.6). One on 1.7.0
        -- says F 1 while held in it and F 2 while down waiting (down, above); this is for one on 1.6.8 or older, whose F 0
        -- comes as they die.)
        local t = p.target
        local fell = t ~= nil and t.MaxHp ~= nil and t.MaxHp > 0 and t.Hp ~= nil and t.Hp <= 0
        if (was or theirs) and on ~= "1" and not down and not (fell and net.fightingHere(localPawn())) then
            if from == nil and isClient() then
                -- (The host's fights are all over: none comes back at this player's death. Only those the host told of:
                -- this player's own, announced to the host, stay theirs, and its kill still runs the boss's real death.)
                for name in pairs(net.partnerBosses) do
                    net.hostBosses[name] = nil
                end
            end
            local whose = net.party and (from or 1) or nil
            local over = {}
            for name in pairs(net.partnerBosses) do
                if whose == nil or net.fightOf[name] == whose then
                    log("The other player's fight with " .. name .. " is over there: over here too.")
                    local otherBoss = false
                    for bn in pairs(net.partnerBosses) do
                        if bn ~= name then otherBoss = true; break end
                    end
                    if net.clearDynSpawned and not otherBoss then net.clearDynSpawned(true) end
                    -- (Asked before its end here: whether this player is in it is known till then. handover.lost.)
                    local boss = enemyByName[name]
                    local alone = isHost() and net.joinedBoss ~= name and not net.struck[name]
                    if alone and valid(boss) then
                        local at = boss:K2_GetActorLocation()
                        alone = not handover.hostIn(name, boss:GetAddress(),
                            net.localLoc and handover.dist(at.X, at.Y, at.Z, net.localLoc) or 0)
                    end
                    endBossFight(name, boss)
                    net.fightOf[name] = nil
                    over[name] = true
                    if alone then
                        handover.lost(name)     -- (a lost fight starts over, as the game has it)
                    end
                end
            end
            if from == nil and isClient() then
                -- (With the bosses the host killed in this fight, their names gone from it already: see handlers.K. A
                -- duplicate of one, or another phase, stood by the arena and its bell: "in combat".)
                for name, at in pairs(net.endedInFight or {}) do
                    if os.clock() - at < 600 then
                        over[name] = true
                    end
                end
                net.endedInFight = {}
                net.putDownLeftBosses(over)
            end
        end
    end

    -- Guest: a boss has stood at a floor of the host's game's own, a plain killing blow from a guest's world not taken
    -- there (FB <boss>, the host's net.finisherSaid): it falls only to a finishing move, this player's own counting
    -- (net.finishingMove). Said, so a copy that stands up again at every blow isn't a riddle. (This game can't tell by
    -- itself: every copy here is held at 1 till the host says.)
    handlers.FB = function(name, from)
        if from ~= nil or not isClient() or not name or name == "" or #name > MAX_CHEST_NAME then
            return
        end
        if valid(enemyByName[name]) then
            log(name .. " falls only to a finishing move: a plain killing blow from here isn't its end.")
            if api.status then
                api.status.notify("finisher", "this boss falls only to a finishing move: a plain blow can't end it.", true)
            end
        end
    end

    -- Guest: the host, down, has let its fight with this boss go (FN <boss>): it stood at a floor of its game's own for
    -- FINISHER_WAIT_S with nobody's finishing move made (net.finisherWaits). Said, since nothing else told why the
    -- fight ends. And the fight that ends now is one the host lost, however long ago they fell (putDownLeftBosses).
    handlers.FN = function(name, from)
        if from ~= nil or not isClient() or not name or name == "" or #name > MAX_CHEST_NAME then
            return
        end
        net.hostDownAt = os.clock()
        log("The host is down and nobody made the finishing move on " .. name .. ": the fight starts over.")
        if api.status then
            api.status.notify("hold", "nobody made this boss's finishing move: the fight starts over.", true)
        end
    end

    -- Guest, the host's fight over: a copy of that boss still standing here is put down if the host killed it or this save had
    -- it beaten (brought back for the fight). Left, it stood with its own AI for good: this player was "in combat" at every
    -- bell near it and shut out of the next boss's arena. Its K could miss it: a phase not paired with the host's id, or one
    -- not loaded then. By its name, or another phase of it (game.phaseGroup).
    -- (A fight the host lost, not left: the host down when it ended, or a little before (F 2, or its line at 0 health). The
    -- boss lives on there and the host comes back for it: one brought back here stays. Put down at once, the boss was gone
    -- from the guest's world on the host's next try, its hits at nothing (player report 11-09).)
    net.LOST_FIGHT_S = 120
    function net.putDownLeftBosses(over)
        local lost = (net.hostDownAt and os.clock() - net.hostDownAt < net.LOST_FIGHT_S)
            or (net.target and net.target.Hp and net.target.MaxHp and net.target.MaxHp > 0 and net.target.Hp <= 0)
        local groups = {}
        for name in pairs(over) do
            if net.hostKilled[name] or (net.broughtBack[name] and not lost) then
                groups[(game.phaseGroup and game.phaseGroup(name)) or name] = name
            end
        end
        if next(groups) == nil or not game.listEnemies then
            return
        end
        game.after(1.0, function()
            for _, actor in pairs(game.listEnemies(true) or {}) do
                if valid(actor) and not game.isDead(actor) and game.isBoss and game.isBoss(actor) then
                    local own = enemyName(actor, actor:GetAddress())
                    local why = groups[own] or groups[(game.phaseGroup and game.phaseGroup(own)) or own]
                    if why then
                        log("Boss " .. own .. " still standing here after the host's fight with " .. why .. ": put down.")
                        game.kill(actor)
                    end
                end
            end
        end)
    end

    -- In a boss fight here, as F tells it: one of this game's own (its bar, not one shown for a partner), or a partner's this
    -- player is in: walked into (E at the black wall, F3), or, on a guest, struck since their last respawn and still near it.
    -- A copy's bar alone isn't being in it: at the black wall, at a bell by the arena or far off, its F 1 kept a dead player
    -- waiting on nobody, while that player's own F 1 kept the copy up. Never a joiner's watch.
    net.FIGHT_NEAR_CM = 10000
    net.struck = net.struck or {}         -- boss id -> true: this player hit it in this fight, or it went for them
    net.struckAt = net.struckAt or {}     -- enemy id -> os.clock() of this player's last blow on it (handover.byHere)
    net.capped = net.capped or {}         -- client: a copy's address -> { name, most }: its own game holds no more (syncEnemy)
    net.RISE_S = 15     -- a boss whose fight begins this soon after its death here is that boss up again (joinBossFight)
    function net.fightingHere(pawn)
        if net.watchingFight then
            return false
        end
        for _, boss in ipairs(game.bossActors()) do
            local addr = boss:GetAddress()
            local mirror = game.isMirrorBar and game.isMirrorBar(boss)
            -- (A party guest's copy of one asleep on the host that this game doesn't run, its bar the game's own: no
            -- fight of this player's. The game starts a stopped AI again by itself, a partner's figure beside the copy
            -- rouses it in that moment, and the game puts its bar up for it; the copy is stopped again, its player 42 m
            -- off, and they were told as in the fight for as long as that bar stood. The bench, three copies. Whose it
            -- is to run, and so whose fight: handover.byHere.)
            if not mirror and net.party and isClient() and handover.live[addr] == nil then
                local r = net.remoteEnemies[enemyName(boss, addr)]
                mirror = r ~= nil and r.Asleep == true
            end
            if not mirror then
                return true
            end
            for name in pairs(net.partnerBosses) do
                local e = enemyByName[name]
                if valid(e) and e:GetAddress() == addr and (net.joinedBoss == name or (net.struck[name] and valid(pawn)
                    and gap3d(pawn:K2_GetActorLocation(), boss:K2_GetActorLocation()) <= net.FIGHT_NEAR_CM)) then
                    return true
                end
            end
        end
        return false
    end

    local function tellFight(now)
        -- (In a fight here, or down in one with the respawn held for it or still deciding. The game takes the bar down as
        -- the player dies; the F 0 that followed ended the partner's copy, whose own F 0 let this respawn go.)
        if net.fightingHere(localPawn()) or net.holdWanted
            or (net.toldFighting and (game.inCutscene() or net.holdLooking)) then
            net.fightHereAt = now
        end
        -- (A bar that went up and came down between two looks here, a figure's as its player arrives by it: its B went
        -- out, no F 1 followed, and nothing ended its mirror in the other worlds: their bar up and their walls shut
        -- for a fight that never was. The bench, 11-17: Wan Jun's and Peng Meng's bars, up for 0.04 and 0.07 s. So
        -- a moment after a B with no fight told since, "no fight" is told again: it ends there what the B began.)
        if net.fightRetellAt and now >= net.fightRetellAt then
            net.fightRetellAt = nil
            if not net.toldFighting then
                net.fightToldAt = 0
            end
        end
        local fighting = now - (net.fightHereAt or -FIGHT_GAP_S) < FIGHT_GAP_S
        -- Down in the fight and waiting for it (F 2): the game took this player's bar down as they died, and "no fight"
        -- ended the partner's copy of it, so their bar went, they told "no fight" back, and this player, the host above all
        -- (whose world the boss is), stopped waiting and respawned at once (player report 11-08). Not a fight to wait on
        -- either: two players both down don't hold each other.
        local down = not fighting and net.deadSince ~= nil and net.holdLooking == true
        -- (Told again after a gap, a join or a sync start (fightToldAt 0), "no fight" too, once: only a change was ever
        -- said, and a fight's end missed in a gap was never heard.)
        if fighting ~= net.toldFighting or down ~= (net.toldDown == true) or ((fighting or down) and now >= (net.fightToldAt or 0))
            or net.fightToldAt == 0 then
            local again = fighting and net.toldFighting == false
            net.toldFighting, net.toldDown, net.fightToldAt = fighting, down, now + FIGHT_TOLD_S
            sendEvent("F", fighting and 1 or (down and 2 or 0))
            if again then
                -- (A fight back on with no new bar: a boss up again after a fall, its bar up all along (Xiaoxue). Its B is
                -- told again, so the others' copy has its bar, walls and the boss's whole death, not a quiet kill.)
                for _, actor in ipairs(net.ownBosses()) do
                    announceBoss(actor)
                end
            end
        end
    end
    -- A joiner watching a fight is let go after WATCH_MAX_S whatever the fight does: "in a fight" can go on with no end (a
    -- boss left standing with its bar up, a scene, the partner's state gone quiet, which also stops partner.check), and the
    -- player stood there with no control, keys and pad dead, until they quit. Then they're free, with F3 or E to go in.
    -- A boss spawned for the partner's fight, and the same boss come in from this world's own fight scene: one goes.
    extraTicksEarly.extraBosses = function()
        local watch = net.extraBossWatch
        if not watch or next(watch) == nil or not game.dropExtraBoss then
            return
        end
        local now = os.clock()
        if now < (net.extraBossAt or 0) then
            return                  -- (once a second: each look searches the map's enemies)
        end
        net.extraBossAt = now + 1
        for name, mine in pairs(watch) do
            local dropped = now <= mine.untilAt and game.dropExtraBoss(mine, name)
            -- (Not found in its first seconds: maybe not in this world's list yet, not gone.)
            mine.firstLook = mine.firstLook or now
            if dropped == nil and now - mine.firstLook < 3 then
                dropped = false
            end
            if dropped ~= true and (now > mine.untilAt or dropped == nil) then
                watch[name] = nil           -- (over, or the one spawned here is gone or dead anyway)
            elseif dropped then
                watch[name] = nil
                log("Two of " .. name .. " here: the one spawned for the other player's fight went; this world's own is the one.")
                if game.refreshEnemyIds then
                    game.refreshEnemyIds(true)
                end
            end
        end
    end

    -- (30 s, was 180: a joiner lost 3 minutes at every link while the host fought, "just stands there, no control". The trip
    -- to the host still comes once the fight is over: see partner.check.)
    net.WATCH_MAX_S = 30
    extraTicksEarly.watchCap = function()
        if net.watchHeld and os.clock() - (net.watchHeldAt or os.clock()) > net.WATCH_MAX_S then
            net.watchGaveUp = true
            watchFight(false)
            if api.status then
                api.status.notify("join", "the fight is taking long: you're free to move. F3 takes you to your partner.")
            end
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
                api.status.notify("join", "your partner is in a boss fight: you'll join them when it's over. F3 takes you in now.")
            end
            local p = fightToWatch()
            if valid(pawn) and p then
                pawn.CharacterMovement:SetMovementMode(MOVE_NONE, 0)
                game.setMinHealth(pawn, 1)
                game.spectate(p.ghost)
                net.watchHeld, net.watchHeldAt = true, os.clock()
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

    -- A partner a dead player's respawn can wait for: linked, on this map, up (a second at 0 health is down, as for the
    -- figure). Not "their figure is shown": one hidden for a scene (a boss's phase, an execution, on either side) let the
    -- respawn go with them still fighting.
    function net.upHere(p)
        local t = p.target
        if t == nil or p.partnerGone or not sameMap(t) then
            return false
        end
        local zero = t.MaxHp ~= nil and t.MaxHp > 0 and t.Hp ~= nil and t.Hp <= 0
        return not (zero and (p.zeroSince == nil or os.clock() - p.zeroSince >= 1.0))
    end

    -- Host, down and held in its fight: a boss of that fight has stood at a floor of its game's own (pbz.lua's
    -- atOwnFloor) since a partner's plain killing blow wasn't taken there (net.floorRefused, handlers.D), FINISHER_WAIT_S
    -- on end. It falls only to a finishing move (the first map's Axe chief), and nobody has made one: this player
    -- can't, and the partner's own, which counts since 395, hasn't come in three minutes. Before 383 that fight went on
    -- with nothing to win till the partner fell too or the hold ran out, a quarter of an hour (a report on 1.7.3,
    -- 11-18: "the host died and i was able to kill the boss alone but when it came to combat finish..."); from 383 it
    -- started over 20 s on, which would cut short a partner's tries at the finishing move now. The boss's name then.
    -- Not while a sequence plays here: a phase's scene starts from such a floor by
    -- itself, well inside that wait. (Any sequence, not inCutscene: that asks who has the camera, and a downed player's
    -- view is this mod's own, on a partner. In an arena where one runs all fight long this never says so, and the wait
    -- is as it was.) Nor for one a guest's game runs: its floor here is the hold's. (Not by the game's mark for the
    -- finishing move, GE_CanLowHealthExecute: with the host down it wasn't on the host's boss, the bench, run186.)
    -- (On net, as LOST_FIGHT_S is: this function is at Lua's 200 locals.)
    net.FINISHER_WAIT_S = 180.0
    net.floorRefused = net.floorRefused or {}       -- boss id -> os.clock() of a partner's killing blow not taken at its floor
    -- (The boss of this player's fight that stands so just now, or nil: asked by a host who's down, here, and by one
    -- who's up, net.finisherSaid.)
    function net.finisherAt()
        local waits = nil
        local quiet = isHost() and game.atOwnFloor and not (game.sequenceOn and game.sequenceOn())
        for name in pairs(net.fightNames or {}) do
            local actor = enemyByName[name]
            if not (game.atOwnFloor and valid(actor) and game.atOwnFloor(actor)) then
                net.floorRefused[name] = nil        -- (off its floor: a blow not taken there before is of no account now)
            elseif quiet and not waits and net.floorRefused[name] and not net.guestRuns[name] then
                waits = name
            end
        end
        return waits
    end
    function net.finisherWaits(now)
        local waits = net.finisherAt()
        -- (Nor while another player's own fight is on, in a party: this respawn refreshes the world under it, a host's
        -- death being everyone's (handlers.R). The hold waited for that fight before 383, and does still. The ninth review.)
        for other in pairs(waits and net.party and net.partnerBosses or {}) do
            local slot = net.fightOf[other] or 1
            if slot ~= 1 and net.peers[slot] and net.peers[slot].fights and net.upHere(net.peers[slot]) then
                waits = nil
            end
        end
        if not waits then
            net.finisherSince = nil
            return nil
        end
        net.finisherSince = net.finisherSince or now
        return now - net.finisherSince >= net.FINISHER_WAIT_S and waits or nil
    end

    -- Host: such a boss has stood at its floor for FINISHER_TELL_AFTER_S since a partner's plain killing blow wasn't
    -- taken there: it falls only to a finishing move. A partner's own counts (handlers.D's X), a plain blow doesn't, and
    -- nothing told either player so: their copy stood up again at each one (the bench, 11-18, run205). Said to each
    -- side, FB to the guests and this player's own while up: once in FINISHER_TELL_S a boss, and then only for a blow
    -- not taken since. Not at once: a phase's scene starts from such a floor by itself, well inside that wait. (A
    -- count of its own, not the hold's.)
    net.FINISHER_TELL_AFTER_S = 20.0
    net.FINISHER_TELL_S = 120.0
    net.finisherTold = net.finisherTold or {}       -- boss id -> os.clock() of when it was last said
    function net.finisherSaid(now, up)
        -- (A note of one that's of no fight of this player's, off its floor or gone: dropped, so this isn't asked for good.)
        for name in pairs(net.floorRefused) do
            if not (game.atOwnFloor and valid(enemyByName[name]) and game.atOwnFloor(enemyByName[name])) then
                net.floorRefused[name] = nil
            end
        end
        local waits = net.finisherAt()
        if not waits then
            net.finisherSaySince = nil
            return
        end
        net.finisherSaySince = net.finisherSaySince or now
        local last = net.finisherTold[waits] or -1e9
        if now - net.finisherSaySince >= net.FINISHER_TELL_AFTER_S and now - last >= net.FINISHER_TELL_S
            and net.floorRefused[waits] > last then
            net.finisherTold[waits] = now
            -- (Not where a partner's finishing move isn't its end either, handlers.D: a phase's floor, or another phase
            -- of it to come. Told there, the guest made one, it wasn't taken, and the word came again two minutes on.
            -- The tenth review's read of 396.)
            local actor = enemyByName[waits]
            if (valid(actor) and game.healthFloor and game.healthFloor(actor) > HELD_HP + 0.5)
                or (game.phaseAfter and game.phaseAfter(waits)) then
                return
            end
            sendEvent("FB", waits)
            log("A partner's killing blow on " .. waits .. " isn't its end: it falls only to a finishing move, theirs or this player's.")
            if up and api.status then
                api.status.notify("finisher", "this boss falls only to a finishing move: a plain blow can't end it.", true)
            end
        end
    end

    local function holdForFight(pawn)
        if not net.holdLooking then
            return
        end
        local now = os.clock()
        if net.holdWanted and not net.respawnHeld then
            net.respawnHeld = game.holdRespawn(pawn, true)    -- (looked for each turn till held: the screen goes on by itself)
        end
        if now < (net.holdLookAt or 0) then
            return
        end
        net.holdLookAt = now + HOLD_LOOK_S
        local up, who = false, nil
        for _, p in ipairs(partners()) do
            if net.upHere(p) then
                up = true
                local fights = (net.party and p.fights) or (not net.party and net.partnerFighting)
                if fights == true and who == nil then
                    who = p
                end
            end
        end
        local waited = now - net.deadSince
        local finisher = who and not net.pvp and net.finisherWaits(now) or nil
        if who and not net.pvp and waited < HOLD_MAX_S and not finisher then
            if not net.holdWanted then
                net.holdWanted = true
                log("Down in a boss fight " .. (net.party and PLAYERS[who.number or 1].name or "your partner")
                    .. " is still in: your respawn waits, and the boss keeps its health.")
            end
            net.respawnHeld = game.holdRespawn(pawn, true)
            if net.respawnHeld and not net.holdTold then
                net.holdTold = true
                if api.status then
                    api.status.notify("hold", "you're down: you'll be back when the fight is over.")
                end
            end
        elseif finisher or not up or net.pvp or waited >= HOLD_MAX_S or waited >= HOLD_GRACE_S then
            if finisher then
                -- (Said to the others too, FN: nothing else told them why the fight ends.)
                log("Down, and nobody has made the finishing move on " .. finisher .. " (held at a floor of its game's own, "
                    .. "a partner's killing blow not taken there): the fight starts over. Your respawn goes on.")
                sendEvent("FN", finisher)
                if api.status then
                    api.status.notify("hold", "nobody made this boss's finishing move: the fight starts over.", true)
                end
            elseif net.holdWanted then
                log("The fight is over for you (the boss is down, or nobody's left in it): your respawn goes on.")
            end
            net.holdLooking, net.holdWanted, net.respawnHeld, net.finisherSince = false, false, false, nil
            net.floorRefused = {}       -- (that fight's over for this player: a note of it means nothing in the next)
            if game.setDownBody then game.setDownBody(pawn, false) end
            game.holdRespawn(pawn, false)
        end
    end

    -- What a boss of this world paid while this player was down (pbz.lua's payOwed), settled: what it lacks given, or the
    -- dust the game kept here shared (C). False while it can't be told yet.
    function net.settleOwed(pawn)
        local paid, share, kept = game.payOwed(pawn)
        if kept then
            log(string.format("Down when the boss died: what it paid was kept here; %d dust of it to the others.",
                math.floor(share)))
        elseif paid and #paid > 0 then
            log("Down when the boss died: what it paid is yours now: " .. table.concat(paid, ", ") .. ".")
        end
        if share and share > 0 then
            sendEvent("C", math.floor(share))
        end
        return paid ~= nil
    end

    local function watchOwnDeath()
        local pawn = localPawn()
        if pawn == nil or not game.isDead then
            return
        end
        if game.isDead(pawn) then
            if net.deadSince == nil then
                net.deadSince = os.clock()
                -- (Or F 1 still told: a bar the game took down for a scene, a boss's grab say, more than 3 s before.)
                net.holdLooking = net.toldFighting == true or net.deadSince - (net.fightSeenAt or -1e9) <= IN_FIGHT_S
                net.holdTold, net.holdWanted, net.respawnHeld = false, false, false
                if game.hideAliveScreen then
                    game.hideAliveScreen()
                end
                if game.noteDown then
                    -- (Down again before what a boss owed was settled: its pay come, settled now; not come, this down is
                    -- the last one's again (pbz.lua's reopenDown). Left as it was, a boss falling now was owed nothing.
                    -- The reviews.)
                    if game.owedBosses and game.downAt and game.downAt.up then
                        local st = game.owedState(pawn)
                        if st and st.kept then
                            net.settleOwed(pawn)
                        elseif st then
                            game.reopenDown(net.holdLooking and net.fightNames or nil)
                        else
                            game.owedBosses, game.downAt = nil, nil
                        end
                    end
                    -- (What a boss of that fight pays while this player is down is owed against this: pbz.lua's payOwed.)
                    game.noteDown(pawn, net.holdLooking and net.fightNames or nil)
                end
            end
            if game.watchOwed then
                game.watchOwed(pawn)
            end
            if not game.spectate then
                return
            end
            -- (Down as well: a guest left at such a boss is told what ends it. net.finisherSaid.)
            if next(net.floorRefused) == nil then
                net.finisherSaySince = nil
            elseif os.clock() >= (net.finisherLookAt or 0) then
                net.finisherLookAt = os.clock() + 1.0
                net.finisherSaid(os.clock(), false)
            end
            holdForFight(pawn)
            if net.holdWanted and game.setDownBody and os.clock() - net.deadSince >= 0.8 then
                local livePartner = isHost() and upPartner() or nil
                game.setDownBody(pawn, true, livePartner and livePartner.ghost or nil)
            end
            local up = upPartner()      -- (whom the camera follows: a figure that's shown)
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
            if game.setDownBody and game.downBodyOff then
                game.setDownBody(pawn, false)
            end
            if net.deadSince ~= nil then
                net.upAt = os.clock()       -- (see onLocalSit)
                if game.downAt then
                    game.downAt.up = true   -- (what the bag and wallet do from here on is this player's own)
                end
            end
            net.deadSince, net.finisherSince = nil, nil
            -- (Up, a partner's plain killing blow not taken at a floor of this game's own: does that boss wait for a
            -- finishing move? Asked a second apart, and only while such a blow is noted. net.finisherSaid.)
            if next(net.floorRefused) == nil then
                net.finisherSaySince = nil          -- (no such blow noted: nothing is counted)
            elseif os.clock() >= (net.finisherLookAt or 0) then
                net.finisherLookAt = os.clock() + 1.0
                net.finisherSaid(os.clock(), true)
            end
            if net.holdLooking then
                net.holdLooking, net.holdWanted, net.respawnHeld = false, false, false
                if game.setDownBody then game.setDownBody(pawn, false) end
                game.holdRespawn(nil, false)
            end
            if game.bossFightActive() then
                net.fightSeenAt = os.clock()
                -- (Its bosses by name, a second apart: the game takes the bar down as its player dies, and one the codex
                -- doesn't call a boss was nobody's boss then. pbz.lua's downBoss.)
                if net.fightSeenAt >= (net.fightNamesAt or 0) then
                    net.fightNamesAt = net.fightSeenAt + 1.0
                    net.fightNames = {}
                    for _, a in ipairs(net.ownBosses()) do
                        net.fightNames[enemyName(a, a:GetAddress())] = true
                    end
                end
            elseif net.fightNames and next(net.fightNames) ~= nil
                and os.clock() - (net.fightSeenAt or 0) > IN_FIGHT_S then
                net.fightNames = {}
            end
            -- What a boss of this world paid while this player was down, given once they're up and settled (pbz.lua's
            -- payOwed): past the respawn's quiet and the wallet's, so a dust rise goes to the partners as earned, as at a
            -- live kill. The game's own pay kept here: its dust to them as well, which went nowhere while down.
            if game.watchOwed then
                game.watchOwed(pawn)
            end
            local now = os.clock()
            if game.owedBosses and now - (net.upAt or -1e9) >= net.OWED_AFTER_S and now >= (net.quietUntil or 0)
                and now >= ((game.dustWatch or {}).quietUntil or 0) and now >= (net.owedLookAt or 0) then
                net.owedLookAt = now + 1.0
                net.settleOwed(pawn)
            end
            -- (Not while a PvP match has the camera on a teammate: arena.lua's, down at 1 health, not dead.)
            if game.isSpectating and game.isSpectating() and not net.watchingFight and not net.arenaWatching then
                game.spectate(nil)
                net.watched = nil
                log("Back on your feet: camera back on you.")
            end
        end
    end

    -- Other modules (pvp.lua) run here every tick while sync is on: name -> function.
    local extraTicks = extraTicksEarly

    -- What a PvP match (net.arena, arena.lua) goes without: the jobs of the enemies and of the world (story, loot, bells, map,
    -- trips to a partner, revives, boss fights). The players' own stay: moves, weapons, bullets, hits, pvp, rules.
    net.ARENA_SKIPS = { puppets = true, scaling = true, twins = true, story = true, scenes = true, blockers = true,
        bags = true, fogPress = true, extraBosses = true, tellFight = true, watchCap = true, mapicon = true, hud = true,
        partner = true, revive = true, arrival = true }

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
        local gap = lastFrame and now - lastFrame or 0
        if gap > 0.5 then
            -- A stall (a load, a trip on the same map, the world streaming in): the world searches wait a while after it.
            -- And no "not in my world" (HAS) for UNSETTLED_S from when it runs again: the trip's own hook had started those
            -- seconds as it began, and a stall of 12-18 s used them up (report 3: enemies invisible after a trip or a bell).
            -- The spawners and enemies are read afresh: one streamed in on a freed address took the old one's id.
            net.quietUntil = math.max(net.quietUntil or 0, os.clock() + net.QUIET_AFTER_LOAD_S)
            net.settleUntil = os.clock() + net.SETTLE_S
            net.unsettledUntil = math.max(net.unsettledUntil or 0, os.clock() + net.UNSETTLED_S)
            if game.forgetActors then
                pcall(game.forgetActors)
            end
        elseif gap > 0.15 and os.clock() < (net.settleUntil or 0) then
            -- Still loading in after it (a 16 s load streamed on for 5 s more and the host crashed in the chains job 0.7 s
            -- after the quiet ended): each hitch keeps them waiting, till the world has run smoothly a while.
            net.quietUntil = math.max(net.quietUntil or 0, os.clock() + net.QUIET_AFTER_LOAD_S)
            net.unsettledUntil = math.max(net.unsettledUntil or 0, os.clock() + net.UNSETTLED_S)
        end
        frameNow, frameDt = now, lastFrame and math.min(now - lastFrame, 0.1) or 0.016
        net.frameNow = now
        lastFrame = now
        -- A budget that fills with time, not a fixed gap after the last send: the tick comes at a slightly different moment
        -- in each frame, and a gap of 1/62 s skipped one frame in four at 60 FPS, so the partner was played further behind.
        -- First of all: nothing below changes this player, and a costly event (a montage loaded, a search) ran before it
        -- here, holding this frame's place back and stamping it that much late.
        sendBudget = math.min(1.5, sendBudget + frameDt * SEND_RATE)
        if sendBudget >= 1 then
            sendBudget = sendBudget - 1
            runStage("sendPlayer", sendPlayer)
        end
        runStage("processEvents", processEvents)
        runStage("readPartner", readPartner)
        -- In a PvP match (arena.lua) there are no enemies to keep in step and none of the world's news: only the players.
        local arena = net.arena
        if not arena then
            runStage("readEnemies", stageReadEnemies)       -- (a host's: the ones a guest's game runs, see handover)
        end
        runStage("steerGhost", steerGhosts)
        if not arena then
            runStage("enemyTurns", stageEnemyTurns)
        end
        for name, fn in pairs(frameTicks) do
            if not (arena and net.ARENA_SKIPS[name]) then
                runStage(name, fn)
            end
        end
        if now >= nextSlow then
            nextSlow = now + SLOW_S
            runStage("watchSlowly", stageWatchSlowly)
            runStage("party", watchParty)
            runStage("visibility", updateVisibility)
            runStage("watchOwnDeath", watchOwnDeath)
            runStage("watchPartner", watchPartner)
        end
        if now >= nextExtra and os.clock() >= (net.quietUntil or 0) then
            nextExtra = now + EXTRA_S
            for name, fn in pairs(extraTicks) do
                if not (arena and net.ARENA_SKIPS[name]) then
                    runStage(name, fn)
                end
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
        -- The body standing for that slot on this PC: this player's own, or a ghost. (With two players there's no
        -- net.slot: the host is 1, the guest 2, and the other one is net.ghost. The bench's PvP finisher found the host's
        -- own slot giving the guest's ghost.)
        playerBody = function(slot)
            local me = net.slot or (isHost() and 1 or 2)
            if slot == me then
                return select(2, getPlayer1())
            end
            if not net.party then
                return (slot == 1 or slot == 2) and net.ghost or nil
            end
            local p = slot == 1 and net or net.peers[slot]
            return p and p.ghost
        end,
        sendEvent = sendEvent,
        announceBoss = announceBoss,
        ownFightOn = net.ownFightOn,
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
