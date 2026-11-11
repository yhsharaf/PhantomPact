-- The partner's moves on their ghost, as animation montages. (From appdoze's PR #5.)
--
-- Whatever montage your character plays (attacks, guard stance, deflects, executions, weapon and Phantom Edge
-- skills, item use, ladders and wall runs...) is sent as "U <montage path> <position>", and the partner's ghost plays
-- the same montage from that point (plus how long ago that was, net.moveAge) with its AnimInstance's own Montage_Play.
-- "U - 0" says it ended.
--
-- Montages show what replaying abilities (M events) couldn't: a ghost often can't activate an ability (guard
-- stance, executions, some weapon skills). PvP keeps abilities: there the ghost's swings must land real hits.
--
-- Checked here (review of PR #5): only the game's move and weapon folders are accepted, the loaded object must really be an
-- AnimMontage, and new loads are capped per minute, so a partner can't make this game load any asset; the ghost
-- isn't steered while a montage plays (game.noteGhostMove), as for ability replays.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local PATH = "^/[%w_/%-]+%.[%w_%-]+$"
    -- The folders the game keeps moves and weapons in (read from a running game, 11-05). Whole content trees before: a
    -- partner could have this game load any asset under /Game/, a map too. The traversal moves' own plugin is new here.
    local ALLOWED_ROOTS = { "^/PBZCombatAsset/ActorData/", "^/HuaShira/Characters/", "^/HuaShira/Animation/",
        "^/HuaShira/SceneProp/", "^/Game/RenewalContent/Actors/", "^/Game/PBZContent/Blueprint/Item/",
        "^/Game/PBZContent/Characters/", "^/Game/RenewalContent/Prototypes/", "^/AdvancedSpecialMove/Montage/" }
    local refusedRoots = {}         -- a folder refused, said once (a real one missing here shows in the log)
    local MAX_NEW_LOADS_PER_MIN = 30
    local RESTART_S = 0.05          -- the same montage at an earlier position = played again
    local STOP_BLEND_S = 0.25       -- the ghost leaves a montage the partner has left over this long

    local moves = { sent = 0, played = 0, failed = 0, refused = 0, partnerSends = false }
    local last, lastPos = nil, 0
    local cache = {}                -- montage path -> its address once checked, or false when it can't be loaded here
    local loads, loadsWindow = 0, os.clock()

    local function animOf(actor)
        local ai
        pcall(function() ai = actor.Mesh:GetAnimInstance() end)
        return valid(ai) and ai or nil
    end

    local function pathOf(m)
        return (m:GetFullName():gsub("^%S+ ", ""))
    end

    local function allowedPath(path)
        if not (path and #path <= 256 and path:match(PATH)) then
            return false
        end
        for _, root in ipairs(ALLOWED_ROOTS) do
            if path:match(root) then
                return true
            end
        end
        local folder = path:match("^(/[^/]+/[^/]+/[^/]+/)") or path:match("^(/[^/]+/[^/]+/)") or "?"
        if not refusedRoots[folder] and (refusedRoots.n or 0) < 20 then
            refusedRoots[folder], refusedRoots.n = true, (refusedRoots.n or 0) + 1
            log("Moves: a path outside the move folders refused: " .. folder)
        end
        return false
    end

    local function isMontage(obj)
        local ok, yes = pcall(function()
            return obj:IsA(StaticFindObject("/Script/Engine.AnimMontage"))
        end)
        return ok and yes == true
    end

    moves.animOf, moves.pathOf, moves.allowedPath = animOf, pathOf, allowedPath

    local ANIM_CHECK_S = 1.0
    local watchedBody, watchedAi, animCheckAt = nil, nil, 0

    -- The guard stance (the right button held) is a pose the animation blueprint holds from tags while the stance's ability
    -- runs: no montage plays between its enter and its exit, and a ghost runs neither. So the sender says whether it's in
    -- the stance, and the ghost holds the last frame of the stance's enter until it's left.
    -- That and how they move go in bits of the place sent every frame (net.moveBits, coop.lua's sendPlayer and heard), so
    -- they're played in step with it and a lost packet is made good by the next. As sure events ("ST 1|0", "GAIT w|j|s",
    -- still played when an older version sends them) they came before the steps they belong to, or after a resend, and
    -- held up the deaths queued behind them.
    local stance = { CHECK_S = 0.1, at = 0, sent = nil, bits = nil }
    -- The flags' bits: 0x10 and 0x20 how they move (1 walking, 2 jogging, 3 sprinting; none: not said), 0x40 in the guard
    -- stance, 0x80 in a move; 0x100 to 0x2000 their posture (Shachi) as a share of its top, 1 to 63 (0: not said), for the
    -- gold strip on a foe's boss bar (arenaui.lua). (No version before reads those six; the native's own are 0x4000 up.)
    local BIT = { STANCE = 0x40, MOVE = 0x80, POSTURE = 0x100, GAITS = { w = 1, j = 2, s = 3, "w", "j", "s" } }
    -- A move played here goes on this long after their place says they're in none, then ends: it's what a lost "U - 0" left
    -- (all three of its copies gone in a burst), a looping one playing on for good. Longer than their place is played
    -- behind, so a move whose U came ahead of its place isn't cut.
    local NO_MOVE_S = 0.3

    -- Sender, every tick: a new montage, or the same one started again, goes to the partner.
    local function watch()
        local pawn = coop.localPawn()
        if pawn == nil then
            return
        end
        -- Asked for again now and then: it's three calls more each time, and this runs every frame.
        local now = os.clock()
        if pawn ~= watchedBody or now >= animCheckAt or not valid(watchedAi) then
            watchedBody, watchedAi, animCheckAt = pawn, animOf(pawn), now + ANIM_CHECK_S
        end
        local ai = watchedAi
        if not ai then
            return
        end
        if now >= stance.at and game.inStance then
            stance.at = now + stance.CHECK_S
            -- (game.inStance goes through every ability the player has, a couple of hundred: that was most of this tick's
            -- cost on the bench host. A stance starts with its enter montage, so it's asked only after one, while in it,
            -- and once to begin with.)
            if stance.sent == nil or stance.sent or stance.maybe then
                local on = game.inStance(pawn)
                if not on and stance.maybe and now >= stance.maybe then
                    stance.maybe = nil
                end
                stance.sent = on
            end
            -- And how they move: the ghost walks, jogs and sprints with them (game.setGhostGait), where it only jogged.
            stance.gait = game.gait and game.gait(pawn) or "j"
            -- And their posture's share (BIT.POSTURE), with this ten times a second. Its top asked once a second (a read
            -- through UE4SS); the posture itself is a read of memory (game.getPosture).
            if now >= (stance.topAt or 0) then
                stance.topAt = now + 1.0
                local ok, top = pcall(function() return pawn.AttributeSetBase.Shachi_Max.CurrentValue end)
                stance.top = ok and type(top) == "number" and top > 0 and top or nil
            end
            local posture = stance.top and game.getPosture and game.getPosture(pawn)
            local share = posture and math.max(0, math.min(1, posture / stance.top))
            stance.bits = (BIT.GAITS[stance.gait] or 2) * 0x10 + (stance.sent and BIT.STANCE or 0)
                + (share and (1 + math.floor(share * 62 + 0.5)) * BIT.POSTURE or 0)
        end
        local m = ai:GetCurrentActiveMontage()
        local inMove = valid(m)
        net.moveBits = stance.bits and stance.bits + (inMove and BIT.MOVE or 0)
        if not inMove then
            -- (Not in a match: every world drops U and Z there, where M plays the figure. The review of 1.7.0: half the
            -- move bytes, sent three times each and forwarded by a party's host, for nothing.)
            if last and not net.arena then
                coop.sendEvent("U", "-", "0")     -- over or cut short: the ghost's copy mustn't play on (some loop)
            end
            last, moves.tellAgain = nil, false
            return
        end
        local addr = m:GetAddress()
        local pos = ai:Montage_GetPosition(m) or 0
        -- (A partner who has just (re)started sync, or joined, wasn't told the move this player is in: told now, as far in
        -- as it is, the same as a new one but for what a new one starts here. handlers.S and J below; issue #16.)
        if moves.tellAgain and addr == last and pos >= lastPos - RESTART_S then
            local path = pathOf(m)
            if allowedPath(path) and (not net.arena or (game.isGuardMove and game.isGuardMove(path))) then
                coop.sendEvent("U", path, string.format("%.2f", pos))
                moves.sent = moves.sent + 1
            end
        end
        moves.tellAgain = false
        if addr ~= last or pos < lastPos - RESTART_S then
            local path = pathOf(m)
            if path and path:find("StanceEnter", 1, true) then
                stance.maybe, stance.at = now + 1.0, 0    -- (asked from now, for a second at least: the ability can lag)
            end
            if game.noteLocalMove then
                game.noteLocalMove()
            end
            if api.revive then
                api.revive.onLocalMontage(m:GetFName():ToString())
            end
            -- (In a match only the guard's moves: the game starts its answer to a blow itself, and a figure can't start the
            -- stance's ability, so no M brings either. Without them the other side never saw a guard raised, and saw its
            -- blow go home on a figure that had turned it aside.)
            if allowedPath(path) and (not net.arena or (game.isGuardMove and game.isGuardMove(path))) then
                coop.sendEvent("U", path, string.format("%.2f", pos))
                moves.sent = moves.sent + 1
            end
        elseif game.noteLocalMove and game.ownHitState and game.ownHitState() == "None" then
            -- (Still in a move of this player's own, not a reaction to a hit: its blows count as theirs to the end. Only a
            -- montage's start did, and a long execution's late blows, or the last of a combo built in one montage, were
            -- taken for nobody's and undone on the copy: "the guest's hits don't stick" (1.6.3's report 1).)
            game.noteLocalMove()
        end
        last, lastPos = addr, pos
    end

    -- Capped, so a flood of different paths can't stall the game with loads.
    local function countLoad()
        local now = os.clock()
        if now - loadsWindow >= 60 then
            loads, loadsWindow = 0, now
        end
        -- (For each partner: one cap for a whole party of five, each with weapons of their own, refused real moves for a
        -- minute at a time.)
        local partners = 1
        pcall(function() partners = math.max(1, #api.coop.partners()) end)
        if loads >= MAX_NEW_LOADS_PER_MIN * partners then
            return false
        end
        loads = loads + 1
        return true
    end

    -- Looked up each time, not kept: a kept object can go with a map, and its address can then be something else entirely, which
    -- valid() can't tell.
    -- (A load that failed is tried again a while later: a move first seen mid-load or mid-trip was refused for the whole
    -- session, and that move never showed on the partner's figure again. Only what isn't a montage is refused for good.)
    local LOAD_AGAIN_S = 30
    local failedAt = {}
    local function montage(path)
        if cache[path] == false or os.clock() - (failedAt[path] or -1e9) < LOAD_AGAIN_S then
            return nil
        end
        local m = StaticFindObject(path)
        if not valid(m) and type(LoadAsset) == "function" then
            -- Moves of a weapon the local player doesn't carry aren't in memory yet.
            if not countLoad() then
                return nil
            end
            pcall(LoadAsset, path)
            m = StaticFindObject(path)
        end
        if valid(m) and (cache[path] == m:GetAddress() or isMontage(m)) then
            cache[path] = m:GetAddress()
            return m
        end
        if valid(m) then
            cache[path] = false
        else
            failedAt[path] = os.clock()
        end
        return nil
    end

    moves.montage = montage
    moves.countLoad = countLoad

    -- A move heard while their figure can't play it (none yet, hidden, its animation not up, the montage not to be had):
    -- held a moment, the newest only, and played as soon as it can be, as far in as it is by then. Dropped, it never came
    -- again: a move is told only as it starts, and a figure made after a trip, or shown again as they got up, stood
    -- through it (issue #16). Not in a match (a guard's move held there could cut their swing, M).
    local HOLD_S, HOLD_TRY_S = 0.75, 0.1

    function moves.hold(p, path, start)
        p.heldMove = { path = path, start = start, at = os.clock(), tryAt = 0 }
    end

    -- Their move is over ("U - 0", or their place says so: see heardMoveBits): the ghost's copy blends out, unless it's the
    -- guard stance's pose, held until the stance is left.
    function moves.endMove(p)
        p.ghostMoveAt, p.heldMove = nil, nil
        if p.stance and (p.stanceHeld or (p.ghostPath or ""):find("StanceEnter", 1, true)) then
            return
        end
        if not net.pvp and valid(p.ghostMontage) and valid(p.ghost) then
            local ai = animOf(p.ghost)
            if ai then
                pcall(function() ai:Montage_Stop(STOP_BLEND_S, p.ghostMontage) end)
            end
        end
    end

    coop.handlers.U = function(rest, from)
        local p = coop.peerOf(from)
        local path, pos = (rest or ""):match("^(%S+)%s+(%S+)$")
        pos = tonumber(pos)
        if path == "-" then
            moves.endMove(p)
            return
        end
        if not (allowedPath(path) and pos and pos == pos and pos >= 0 and pos < 600) then
            moves.refused = moves.refused + 1
            return
        end
        moves.partnerSends = true
        p.heldMove = nil            -- (a newer move: one held for them is over)
        -- (In PvP the figure plays their abilities, M, but for the guard's moves: see the sending side. One older than a move
        -- of theirs already started, come late behind it, would cut that move: dropped; the review.)
        if net.pvp and (not (game.isGuardMove and game.isGuardMove(path)) or not valid(p.ghost) or p.ghostHidden
            or os.clock() - net.moveAge() < (p.lastMoveSentAt or -1e9)) then
            return
        end
        local start = pos + net.moveAge()
        if not valid(p.ghost) or p.ghostHidden then
            moves.hold(p, path, start)
            return
        end
        local m = montage(path)
        local ai = animOf(p.ghost)
        if not (m and ai) then
            if net.pvp then
                moves.failed = moves.failed + 1
            else
                moves.hold(p, path, start)
            end
            return
        end
        moves.playOn(p, m, ai, path, start)
    end

    -- A held move, played once their figure can (looked at HOLD_TRY_S apart), as far in as it is by now. Let go after
    -- HOLD_S, or in a match (counted as failed if their figure was there to play it).
    local function playHeld(now)
        for _, p in ipairs(coop.partners()) do
            local h = p.heldMove
            if h and now >= h.tryAt then
                h.tryAt = now + HOLD_TRY_S
                local shown = valid(p.ghost) and not p.ghostHidden
                if net.pvp or now - h.at > HOLD_S then
                    p.heldMove = nil
                    if shown then
                        moves.failed = moves.failed + 1
                    end
                elseif shown then
                    local m, ai = montage(h.path), animOf(p.ghost)
                    if m and ai then
                        p.heldMove = nil
                        moves.playOn(p, m, ai, h.path, h.start + (now - h.at))
                    end
                end
            end
        end
    end

    -- One of their moves on their figure, start seconds in.
    function moves.playOn(p, m, ai, path, start)
        if game.isGuardReaction and game.isGuardReaction(path) then
            -- Their guard turned a blow aside: a flinch our own blow left on the figure (for show only) goes first, and the
            -- figure is shielded a moment (pvp.lua: p.guardAt) so a blow landing here after this doesn't flinch it again.
            p.guardAt = os.clock()
            if game.clearHitState then
                game.clearHitState(p.ghost)
            end
        end
        local ok = pcall(function() ai:Montage_Play(m, 1.0, 0, start, true) end)
        if ok then
            moves.played = moves.played + 1
            p.ghostMontage, p.ghostPath, p.stanceHeld, p.ghostMoveAt = m, path, nil, os.clock()
            if path:find("StanceEnter", 1, true) then
                p.stancePath = path
                moves.holdStance(p, m, start)
            elseif game.isGuardReaction and game.isGuardReaction(path) then
                p.guardPlays = (p.guardPlays or 0) + 1
                moves.backToGuard(p, m, start)      -- (whether their guard's bit is here yet or not: it comes with their place)
            end
            if game.noteGhostMove then
                game.noteGhostMove(p.ghost)
            end
        else
            moves.failed = moves.failed + 1
        end
    end

    -- The stance's enter, near its end: still in the stance, it stops there and holds (looked up again: nothing kept). Before
    -- its blend out begins: paused in that, it went all the same. A timer can come late (a game in the background runs few
    -- frames): one that finds it gone, or going, plays it again from that moment and holds it at once.
    function moves.holdStance(p, m, start)
        local addr, ghost = m:GetAddress(), p.ghost
        local hold, fades = 0, 0
        pcall(function()
            local out = m.BlendOutTriggerTime
            if not (type(out) == "number" and out >= 0) then
                out = m.BlendOut.BlendTime
            end
            fades = m:GetPlayLength() - (tonumber(out) or 0.25)
            hold = math.max(0, fades - 0.12)
        end)
        game.after(math.max(0, hold - start), function()
            if not (p.stance and valid(ghost) and ghost == p.ghost and valid(p.ghostMontage) and p.ghostMontage:GetAddress() == addr) then
                return
            end
            local ai = animOf(ghost)
            local held = ai and pcall(function()
                local now = ai:GetCurrentActiveMontage()
                if not (valid(now) and now:GetAddress() == addr) or ai:Montage_GetPosition(p.ghostMontage) >= fades - 0.01 then
                    ai:Montage_Play(p.ghostMontage, 1.0, 0, hold, true)
                end
                ai:Montage_Pause(p.ghostMontage)
            end)
            if held then
                p.stanceHeld = addr
            end
        end)
    end

    -- Their guard's answer to a blow (its Defence move) played on the figure: back into the guard's pose as it goes, if they
    -- still hold the guard then, as their own body goes. (The bench, 11-07: the figure stood at ease after it with the guard
    -- still up on their screen. Timed by the move's length, the guard came back late: the move was over well before it.) The
    -- figure is looked at every 50 ms while the move plays: as it starts to blend out, or is over, the guard's pose. Not over
    -- a move of theirs begun meanwhile, nor after the next Defence move (each play its own count: p.guardPlays).
    function moves.backToGuard(p, m, start)
        local path, addr, ghost, play = p.stancePath, m:GetAddress(), p.ghost, p.guardPlays
        local fades, untilAt = 0.6, os.clock() + 3.0
        pcall(function()
            local out = m.BlendOutTriggerTime
            if not (type(out) == "number" and out >= 0) then
                out = m.BlendOut.BlendTime
            end
            fades = m:GetPlayLength() - (tonumber(out) or 0.25)
            untilAt = os.clock() + math.max(0.3, m:GetPlayLength() - (start or 0)) + 0.3
        end)
        local function look()
            if not (path and p.guardPlays == play and valid(ghost) and ghost == p.ghost and valid(p.ghostMontage)
                and p.ghostMontage:GetAddress() == addr) or os.clock() > untilAt then
                return
            end
            local ai, now = animOf(ghost), nil
            pcall(function() now = ai and ai:GetCurrentActiveMontage() end)
            if valid(now) and now:GetAddress() ~= addr then
                return          -- (a move of theirs)
            end
            local going = not valid(now)
            if not going then
                pcall(function() going = ai:Montage_GetPosition(now) >= fades - 0.05 end)
            end
            if not going then
                game.after(0.05, look)
                return
            end
            local enter = p.stance and montage(path)
            if enter then
                p.ghostMontage, p.ghostPath, p.stanceHeld = enter, path, nil
                moves.holdStance(p, enter, math.huge)
            end
        end
        game.after(0.05, look)
    end

    local function gaitTo(p, gait)
        if (gait == "w" or gait == "j" or gait == "s") and gait ~= p.gait then
            p.gait = gait
            if valid(p.ghost) and game.setGhostGait then
                game.setGhostGait(p.ghost, gait)
            end
        end
    end

    local function stanceTo(p, on)
        p.stance = on
        if not p.stance and p.stanceHeld then
            -- Left with no exit of its own to play (cut short): the held pose goes.
            local ai = valid(p.ghost) and animOf(p.ghost)
            if ai and valid(p.ghostMontage) and p.ghostMontage:GetAddress() == p.stanceHeld then
                pcall(function() ai:Montage_Stop(STOP_BLEND_S, p.ghostMontage) end)
            end
            p.stanceHeld = nil
        elseif p.stance and not p.stanceHeld and (p.ghostPath or ""):find("StanceEnter", 1, true) and valid(p.ghostMontage)
            and valid(p.ghost) then
            -- Said after the enter's own hold came (a slow link: the stance comes with their place, played behind): held from
            -- where the enter is now, or at once if it's over.
            local ai, at = animOf(p.ghost), nil
            if ai then
                pcall(function()
                    at = ai:Montage_IsPlaying(p.ghostMontage) and ai:Montage_GetPosition(p.ghostMontage) or math.huge
                end)
                moves.holdStance(p, p.ghostMontage, tonumber(at) or math.huge)
            end
        end
    end

    -- Every place heard from a player that says how they move (see stance): only what changed is done.
    function net.heardMoveBits(p, flags)
        gaitTo(p, BIT.GAITS[(flags >> 4) & 3])
        -- Their posture's share of its top (BIT.POSTURE), or nil when it isn't said (an older version, a bot): a foe's gold
        -- strip on the boss bar (arenaui.lua's postureOf).
        local q = (flags >> 8) & 0x3F
        p.postureShare = q > 0 and (q - 1) / 62 or nil
        local on = flags & BIT.STANCE ~= 0
        if on ~= (p.stance == true) then
            stanceTo(p, on)
        end
        -- In no move since before the one played here began, for NO_MOVE_S: its "U - 0" was lost. (Not from a place only
        -- guessed at, with nothing new heard: a stopped link says nothing about their moves.)
        if flags & BIT.MOVE ~= 0 then
            p.noMoveSince = nil
        elseif flags & 0x8000 == 0 then
            local now = os.clock()
            p.noMoveSince = p.noMoveSince or now
            if p.ghostMoveAt and p.ghostMoveAt < p.noMoveSince and now - p.noMoveSince >= NO_MOVE_S then
                moves.endMove(p)
            end
        end
    end

    coop.handlers.GAIT = function(rest, from)
        gaitTo(coop.peerOf(from), rest)
    end

    coop.handlers.ST = function(rest, from)
        stanceTo(coop.peerOf(from), rest == "1")
    end

    ------------------------------------------------------------------ what the partner holds

    -- Attacks came out empty-handed: the abilities that draw the blade don't run on a ghost, and its gear is this PC's
    -- backpack, not the partner's. So the sender says what it holds and whether it's drawn ("W <weapon config> <0|1>"),
    -- and the ghost's own weapons component is brought to that (and kept there: the ghost's blueprint follows this PC's
    -- backpack, and a new ghost starts from it).
    --
    -- A Phantom Edge weapon is the same with a slot of its own, drawn for its skill alone ("E <weapon config> <0|1>"). Set on the
    -- ghost's component, it hangs where the partner's does. It has moves of its own too: a cannon's mesh is folded away to nothing
    -- until it plays the montage that opens it, so what that mesh plays goes as well ("Z <montage> <position>").
    local GEAR_WATCH_S = 0.1        -- how often the sender checks that the blade is drawn
    local GEAR_PATH_S = 0.5         -- and which weapon it is
    local GEAR_DRESS_S = 0.25       -- how often the ghost is checked against the partner
    local GEAR_SWAP_S = 5.0         -- a weapon change that didn't take isn't tried again sooner
    local GEAR_SETTLE_S = 6.0       -- a new ghost is left alone this long
    local gear = { watchAt = 0, pathAt = 0, edgePathAt = 0 }
    local SHACHI = "Weapon.Slot.Shachi"

    -- What one other player holds, kept with them.
    local function gearOf(p)
        p.gear = p.gear or { dressAt = 0, swapAt = 0 }
        return p.gear
    end

    local function mainSlot()
        gear.slot = gear.slot or { TagName = FName("Weapon.Slot.Main") }
        return gear.slot
    end

    local function edgeSlot()
        gear.edge = gear.edge or { TagName = FName(SHACHI) }
        return gear.edge
    end

    local function heldConfig(cwc, slot)
        local data = {}
        cwc:GetCurrentWeapon(slot or mainSlot(), data, false, {})
        return valid(data.WeaponConfig) and pathOf(data.WeaponConfig) or nil
    end

    -- The actor hanging on a body for its Phantom Edge weapon. It's the component's to spawn and take away, so it's looked for.
    local function edgeActor(body)
        local list = {}
        body:GetAttachedActors(list, true, true)
        for i = 1, #list do
            local a = list[i]:get()
            local ok, tag = pcall(function() return a.Slot.TagName:ToString() end)
            if ok and tag == SHACHI then
                return a
            end
        end
        return nil
    end

    local function edgeAnim(body)
        local ai
        pcall(function() ai = edgeActor(body).WeaponMesh:GetAnimInstance() end)
        return valid(ai) and ai or nil
    end

    local function isWeaponConfig(obj)
        local ok, yes = pcall(function()
            return obj:IsA(StaticFindObject("/Script/PBZCombatAsset.PBZ_WeaponConfigBase"))
        end)
        return ok and yes == true
    end

    local function watchGear(now)
        if now < gear.watchAt then
            return
        end
        gear.watchAt = now + GEAR_WATCH_S
        local pawn = coop.localPawn()
        if pawn == nil then
            return
        end
        local cwc = pawn["Character Weapons Component"]
        local armed = cwc:IsArmed(mainSlot()) == true
        if now >= gear.pathAt then
            gear.pathAt = now + GEAR_PATH_S
            gear.path = heldConfig(cwc) or gear.path
        end
        if gear.path and (armed ~= gear.sentArmed or gear.path ~= gear.sentPath) then
            gear.sentArmed, gear.sentPath = armed, gear.path
            coop.sendEvent("W", gear.path, armed and 1 or 0)
        end
        armed = cwc:IsArmed(edgeSlot()) == true
        if now >= gear.edgePathAt then
            gear.edgePathAt = now + GEAR_PATH_S
            gear.edgePath = heldConfig(cwc, edgeSlot())
        end
        -- ("-": none. Never said, a partner with none showed this player's own on their figure, from this PC's backpack, and one
        -- who took theirs off kept it hanging there.)
        local edge = gear.edgePath or "-"
        if gear.edgePathAt > 0 and (armed ~= gear.sentEdgeArmed or edge ~= gear.sentEdgePath) then
            gear.sentEdgeArmed, gear.sentEdgePath = armed, edge
            coop.sendEvent("E", edge, armed and 1 or 0)
        end
        if armed then
            local ai = gear.edgeAnim
            if not (valid(ai) and gear.edgeAnimOf == gear.edgePath) then
                ai = edgeAnim(pawn)
                gear.edgeAnim, gear.edgeAnimOf = ai, gear.edgePath
            end
            local m = ai and ai:GetCurrentActiveMontage()
            if valid(m) then
                local addr, pos = m:GetAddress(), ai:Montage_GetPosition(m) or 0
                if (addr ~= gear.edgeMontage or pos < gear.edgePos - RESTART_S) and not net.arena then
                    coop.sendEvent("Z", pathOf(m), string.format("%.2f", pos))
                end
                gear.edgeMontage, gear.edgePos = addr, pos
            end
        end
    end

    coop.handlers.W = function(rest, from)
        local path, armed = (rest or ""):match("^(%S+)%s+([01])$")
        if not allowedPath(path) then
            moves.refused = moves.refused + 1
            return
        end
        local theirs = gearOf(coop.peerOf(from))
        if path ~= theirs.partnerPath then
            theirs.swapAt = 0
        end
        theirs.partnerPath, theirs.partnerArmed = path, armed == "1"
        theirs.dressAt = 0
    end

    coop.handlers.E = function(rest, from)
        local path, armed = (rest or ""):match("^(%S+)%s+([01])$")
        if path == "-" then
            local theirs = gearOf(coop.peerOf(from))
            theirs.edgePath, theirs.edgeArmed, theirs.dressAt = "-", false, 0
            return
        end
        if not allowedPath(path) then
            moves.refused = moves.refused + 1
            return
        end
        local theirs = gearOf(coop.peerOf(from))
        if path ~= theirs.edgePath then
            theirs.edgeSwapAt = 0
        end
        theirs.edgePath, theirs.edgeArmed = path, armed == "1"
        theirs.dressAt = 0
    end

    coop.handlers.Z = function(rest, from)
        local path, pos = (rest or ""):match("^(%S+)%s+(%S+)$")
        pos = tonumber(pos)
        if not (allowedPath(path) and pos and pos == pos and pos >= 0 and pos < 600) then
            moves.refused = moves.refused + 1
            return
        end
        local p = coop.peerOf(from)
        if net.pvp or not valid(p.ghost) or p.ghostHidden or not moves.settled(p) then
            return
        end
        local m, ai = montage(path), edgeAnim(p.ghost)
        if m and ai then
            pcall(function() ai:Montage_Play(m, 1.0, 0, pos + net.moveAge(), true) end)
        end
    end

    -- Weapon configs load like montages: same paths, same cap. Not an AnimMontage, so not through the same cache, and looked up each
    -- time for the same reason: a swap is rare.
    local function weaponConfig(path)
        local cfg = StaticFindObject(path)
        if not valid(cfg) and type(LoadAsset) == "function" and countLoad() then
            pcall(LoadAsset, path)
            cfg = StaticFindObject(path)
        end
        return valid(cfg) and isWeaponConfig(cfg) and cfg or nil
    end

    -- A new ghost, on a map that's most often only just there. A weapon's passive skill starts the moment it's given, and with its
    -- classes still loading after the trip it has no code yet: that was a crash on arrival with a Scarlet Wraithblade. So nothing of
    -- the partner's goes on it for a few seconds, and nothing's fired from it.
    function moves.settled(p)
        return os.clock() - (p.ghostAt or -1e9) >= GEAR_SETTLE_S
    end

    local function dressGhost(p, now)
        local ghost, theirs = p.ghost, gearOf(p)
        if now < theirs.dressAt or not valid(ghost) or p.ghostHidden or not moves.settled(p) then
            return
        end
        theirs.dressAt = now + GEAR_DRESS_S
        local cwc = ghost["Character Weapons Component"]
        local slot = mainSlot()
        if theirs.partnerPath then
            if now >= theirs.swapAt and heldConfig(cwc) ~= theirs.partnerPath then
                theirs.swapAt = now + GEAR_SWAP_S
                local cfg = weaponConfig(theirs.partnerPath)
                if cfg then
                    cwc:SetSlotWeapon(slot, math.max(cwc:GetCurrentWeaponIndex(slot, false) or 0, 0), cfg)
                    log("The ghost now holds " .. theirs.partnerPath:match("([^.]+)$") .. ".")
                end
            end
            if (cwc:IsArmed(slot) == true) ~= theirs.partnerArmed then
                cwc:SetArmed(slot, theirs.partnerArmed)
            end
        end
        -- (In PvP too. There the figure's own abilities (M) draw its Phantom Edge, open it and fire it, but they take the one in
        -- its slot, and the figure has that from this PC's bag: in a match this player's own loadout's, not the foe's. So the
        -- weapon is set there as well. Whether it's drawn stays the abilities' own: their word comes after the M, by the sure
        -- lane, and put it away under the skill it was drawn for. Nor is it changed while drawn: a skill on the figure keeps
        -- its weapon to the end.)
        if theirs.edgePath == "-" then
            if theirs.edgeHiddenOn ~= ghost:GetAddress() then      -- (each new figure starts with it shown)
                theirs.edgeHiddenOn = ghost:GetAddress()
                pcall(function() cwc:SetWeaponForceHide(edgeSlot(), 0, true) end)
            end
        elseif theirs.edgePath then
            slot = edgeSlot()
            if theirs.edgeHiddenOn then
                theirs.edgeHiddenOn = nil
                pcall(function() cwc:SetWeaponForceHide(slot, 0, false) end)
            end
            if now >= (theirs.edgeSwapAt or 0) and not (net.pvp and cwc:IsArmed(slot) == true)
                and heldConfig(cwc, slot) ~= theirs.edgePath then
                theirs.edgeSwapAt = now + GEAR_SWAP_S
                local cfg = weaponConfig(theirs.edgePath)
                if cfg then
                    -- (At its current place in the slot, as the weapon above: the one in hand isn't always the first. With
                    -- a match's loadout on, the bench's players held their second, TigerCannon.)
                    cwc:SetSlotWeapon(slot, math.max(cwc:GetCurrentWeaponIndex(slot, false) or 0, 0), cfg)
                    log("The ghost's Phantom Edge is now " .. theirs.edgePath:match("([^.]+)$") .. ".")
                end
            end
            if not net.pvp and (cwc:IsArmed(slot) == true) ~= theirs.edgeArmed then
                cwc:SetArmed(slot, theirs.edgeArmed)
            end
        end
    end

    function moves.hideGear(ghost, hide)
        local cwc = ghost["Character Weapons Component"]
        local slot = mainSlot()
        cwc:SetWeaponAndScabbardForceHide(slot, math.max(cwc:GetCurrentWeaponIndex(slot, false) or 0, 0), hide)
        cwc:SetWeaponForceHide(edgeSlot(), 0, hide)
        if not hide then
            -- (Shown again, the edge slot too: a partner with no Phantom Edge then showed this player's own, as the
            -- record said it was hidden already. Dressing hides it again.)
            local addr = ghost:GetAddress()
            for _, p in ipairs(coop.partners()) do
                if valid(p.ghost) and p.ghost:GetAddress() == addr then
                    gearOf(p).edgeHiddenOn = nil
                end
            end
        end
    end

    -- The partner has just (re)started sync: it knows nothing yet. (Gait and stance go with every place: nothing to tell
    -- again. The move this player is in, if any, is told again: watch.)
    local partnerStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        gear.sentPath, gear.sentEdgePath, moves.tellAgain = nil, nil, true
        return partnerStarted(rest, from)
    end

    -- Someone new in a party: the same.
    local someoneJoined = coop.handlers.J
    coop.handlers.J = function(rest, from)
        gear.sentPath, gear.sentEdgePath, moves.tellAgain = nil, nil, true
        return someoneJoined(rest, from)
    end

    -- Ability replays only in PvP. (With the sender: in a party it says whose figure swings. Dropped here, every player's
    -- moves were replayed on one figure in a PvP match of three or more; the review of 1.7.0.)
    local replayAbility = coop.handlers.M
    if replayAbility then
        coop.handlers.M = function(rest, from)
            if moves.partnerSends and not net.pvp then
                return
            end
            -- In PvP a move of theirs that isn't the guard's: no guard pose of theirs is held or played over it from here on
            -- (a hold's timer, their guard's bit come late), and a guard move older than it is dropped (handlers.U). (The
            -- review: the stance's enter, held a moment later, cut the attack they had just started on the figure.)
            local p = net.pvp and coop.peerOf(from)
            local path = p and (rest or ""):match("^(%S+)")
            if path and not (game.isGuardMove and game.isGuardMove(path)) then
                p.ghostMontage, p.ghostPath, p.stanceHeld = nil, nil, nil
                p.lastMoveSentAt = os.clock() - net.moveAge()
            end
            return replayAbility(rest, from)
        end
    end

    ------------------------------------------------------------------ props

    -- What a skill puts in a player's hand for a moment, shown on their ghost too. Madman's Broken Sword's drink (right
    -- button + F): the game attaches a wine jar (BP_JiuTan_C) to the left hand for about a second, and the ghost drank from
    -- nothing. Only props on this list: the message names one, and its mesh comes from here, never from the wire. The jar's
    -- own class is a bullet blueprint, so the ghost gets a plain mesh actor with its mesh, not the class.
    local PROPS = {
        BP_JiuTan_C = { mesh = "/HuaShira/Animation/Hero/Hun/SH_Sources/ChiZheCanJian/Hun_JiuTan_002.Hun_JiuTan_002",
            socket = "weapon_l" },
    }
    local PROP_LOOK_S = 0.15        -- this player's hands looked at this often
    local PROP_MAX_S = 4            -- a ghost's prop goes after this long, its end message or not
    local props = { lookAt = 0, mine = {} }

    -- This player: which listed props are attached to the body now; each one that comes or goes is told.
    local function watchProps(now)
        if now < props.lookAt then
            return
        end
        props.lookAt = now + PROP_LOOK_S
        local pawn = coop.localPawn()
        if not valid(pawn) then
            return
        end
        local here = {}
        local l = {}
        pcall(function() pawn:GetAttachedActors(l, true, true) end)
        for i = 1, #l do
            local a = l[i]
            pcall(function() a = a:get() end)
            if valid(a) then
                local okc, cn = pcall(function() return a:GetClass():GetFName():ToString() end)
                if okc and PROPS[cn] then
                    here[cn] = true
                end
            end
        end
        for cn in pairs(here) do
            if not props.mine[cn] then
                coop.sendEvent("PROP", "+", cn)
            end
        end
        for cn in pairs(props.mine) do
            if not here[cn] then
                coop.sendEvent("PROP", "-", cn)
            end
        end
        props.mine = here
    end

    local function dropProp(p, cn)
        local held = p.props and p.props[cn]
        if held then
            p.props[cn] = nil
            if valid(held.actor) and held.actor:GetAddress() == held.addr then
                pcall(function() held.actor:K2_DestroyActor() end)
            end
        end
    end

    local function showProp(p, cn)
        local def = PROPS[cn]
        local ghost = p.ghost
        if not (def and valid(ghost)) or p.ghostHidden then
            return
        end
        dropProp(p, cn)
        local mesh = StaticFindObject(def.mesh)
        if not valid(mesh) and type(LoadAsset) == "function" then
            pcall(LoadAsset, def.mesh)
            mesh = StaticFindObject(def.mesh)
        end
        local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
        local gs, pc = api.gs(), api.getPlayer1()
        local body = ghost.Mesh
        if not (valid(mesh) and valid(cls) and valid(gs) and valid(pc) and valid(body)) then
            return
        end
        local at = ghost:K2_GetActorLocation()
        local tf = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = { X = at.X, Y = at.Y, Z = at.Z },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
        local actor = nil
        local ok = pcall(function()
            local a = gs:BeginDeferredActorSpawnFromClass(pc, cls, tf, 2, nil, 1)
            if valid(a) then
                actor = gs:FinishSpawningActor(a, tf, 1)
            end
        end)
        if not (ok and valid(actor)) then
            return
        end
        pcall(function()
            local c = actor.StaticMeshComponent
            if valid(c) then
                c:SetMobility(2)
                c:SetCollisionEnabled(0)
                c:SetStaticMesh(mesh)
            end
            -- Snapped to the hand's socket, as the game's own jar sits (no offset, scale 1).
            actor:K2_AttachToComponent(body, FName(def.socket), 2, 2, 2, false)
        end)
        p.props = p.props or {}
        p.props[cn] = { actor = actor, addr = actor:GetAddress(), at = os.clock() }
    end

    coop.handlers.PROP = function(rest, from)
        local sign, cn = (rest or ""):match("^([%+%-]) (%S+)$")
        if not (sign and PROPS[cn]) then
            return
        end
        local p = coop.peerOf(from)
        if sign == "+" then
            showProp(p, cn)
        else
            dropProp(p, cn)
        end
    end

    -- A ghost's props go once their time is up, or with the ghost (hidden, gone, sync off).
    local function ageProps(now)
        for _, p in ipairs(coop.partners()) do
            for cn, held in pairs(p.props or {}) do
                if os.clock() - held.at > PROP_MAX_S or not valid(p.ghost) or p.ghostHidden or not net.enabled then
                    dropProp(p, cn)
                end
            end
        end
    end

    function moves.dropAllProps()
        for _, p in ipairs(coop.partners()) do
            for cn in pairs(p.props or {}) do
                dropProp(p, cn)
            end
        end
    end

    -- The tick's parts, called through this table so tools/netlab/perf.lua's profile can time each one.
    local parts = { watch = watch, watchGear = watchGear, dressGhost = dressGhost, watchProps = watchProps,
        ageProps = ageProps, playHeld = playHeld }
    moves.parts = parts

    -- A move goes out in the frame it starts. With the tick below, every other frame at 60 FPS, half went a frame later,
    -- and the ghost skipped that much more of its start (it starts as far in as the move is old).
    coop.frameTicks.moveStarts = function()
        local ok, err = pcall(parts.watch)
        if not ok then
            last = nil
            if err ~= moves.lastError then        -- once per kind of error, not every tick
                moves.lastError = err
                log("moves: " .. tostring(err))
            end
        end
        -- Held moves too, every frame: the quiet after a load or a stall (5 s) holds the extra ticks back, and a move held
        -- for a figure made after a trip was let go before it could play (the review of 339d057). handlers.U plays then.
        ok, err = pcall(parts.playHeld, os.clock())
        if not ok and err ~= moves.lastHeldError then
            moves.lastHeldError = err
            log("moves (held): " .. tostring(err))
        end
    end

    coop.extraTicks.moves = function()
        local now = os.clock()
        -- (Each on its own: one error in this player's own gear, a load say, left every partner's figure empty-handed.)
        local errs = {}
        local ok, err = pcall(parts.watchGear, now)
        if not ok then
            errs[#errs + 1] = err
        end
        for _, p in ipairs(coop.partners()) do
            local dressed, why = pcall(parts.dressGhost, p, now)
            if not dressed then
                errs[#errs + 1] = why
            end
        end
        if errs[1] and errs[1] ~= gear.lastError then
            gear.lastError = errs[1]
            log("moves (gear): " .. tostring(errs[1]))
        end
        ok, err = pcall(parts.watchProps, now)
        if ok then
            ok, err = pcall(parts.ageProps, now)
        end
        if not ok and err ~= props.lastError then
            props.lastError = err
            log("moves (props): " .. tostring(err))
        end
    end

    -- moves: counters
    function moves.command()
        log(string.format("Moves: sent %d, played on the ghost %d, failed %d, refused %d, partner sends montages: %s",
            moves.sent, moves.played, moves.failed, moves.refused, tostring(moves.partnerSends)))
    end

    return moves
end
