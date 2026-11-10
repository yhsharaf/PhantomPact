-- A partner's hits on enemies, heard and seen: the game's own hit sound and blood on everyone's copy of the enemy.
--
-- A player's own hit plays its sound and blood through the game's hit-effect chooser, asked with the attack's type, its
-- strength and the body's material (BP_HitEffectPlayer_Chooser:GetEffectData: the hero's blade landing a light hit on flesh
-- is SFX_Combat_Hit_SlashTangBlade_Meat_Light and three blood systems). The partner's figure only replays moves (montages,
-- no abilities), so its blade never lands, and their hits made no sound on the other PC (player report 11-09: "it feels
-- like they are hitting air"; bench 11-10: the guest's 12 hits played nothing on the host, the host's 3 nothing on the guest).
--
-- So each PC notes what its chooser was asked for its own hits (a hook: GetEffectData is a Blueprint function, which the
-- script layer sees), and when the mod counts one of those hits on an enemy (a guest's report on the host's enemy, or a
-- health drop on an enemy this game runs), it sends "HX <enemy> <type> <strength> <material>". Everyone else asks their own
-- chooser the same and plays its sound on their copy of that enemy, and its blood where the figure's blade meets the body.
--
-- Not the hitter's slow-down, camera shake or rumble: those are theirs. Not an enemy's deflect of the swing: the game plays
-- deflects through another effect system, not this chooser (asked for a deflect, it gave nothing on the bench). Not in PvP
-- (hits are real there), nor local co-op (player 2's are real too). Older versions drop HX (unknown events are), so with
-- one of those it stays as it was. PartnerHitSounds = On (the ini ships it On; left out, nothing changes).

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local CHOOSER_FN = "/PBZCombatAsset/Prototypes/Hitreact/BP_HitEffectPlayer_Chooser.BP_HitEffectPlayer_Chooser_C:GetEffectData"
    local CHOOSER = "/PBZCombatAsset/Config/HitReact/HitEffect/PBZ_HitreactEffectPlayer_Chooser.PBZ_HitreactEffectPlayer_Chooser"
    local CHOOSER_BASE = "/Script/PBZCombatAsset.HitreactEffectPlayer_PBZBase"     -- (the class that has GetEffectData)
    local HITREACT = "/Script/SGameCombatSystem.HitreactComponent"
    local AK = "/Script/AkAudio.Default__AkGameplayStatics"
    local NIAGARA = "/Script/Niagara.Default__NiagaraFunctionLibrary"

    -- The game's own tags, sent without these heads. (Its attack types are spelled HitReact, the rest Hitreact.)
    local TYPE = "HitReact.AttackType."
    local STRENGTH = "Hitreact.Strength.Income."
    local MATERIAL = "Hitreact.Material."

    local KEEP_S = 0.4          -- a hit's effect waits this long here for the mod to count that hit on an enemy
    local MAX_KEPT = 8
    local OWN_S = 1.5           -- a drop on an enemy this game runs is this player's hit with one of their moves this recent
    local SEEN_S = 1.0          -- a health seen longer ago than this is no measure of a hit (the enemy was away, or not ours)
    local HEAR_CM = 6000        -- a partner's hit is played on an enemy this near this player
    local GAP_S = 0.05          -- one enemy's effects at least this far apart
    local MAX_PER_S = 24        -- partners' effects played per second, at most
    local TOWARD_CM = 25        -- the blood: from the body's bone this far toward the hitter
    local MAX_BLOOD = 4
    local RETRY_S = 5           -- until the chooser is loaded (with the first enemies), the hook is tried this often

    local hitfx = { on = false, sent = 0, played = 0, refused = 0 }
    local kept = {}             -- this player's hits' effects, oldest first: { t, kind, strength, material }
    local hpSeen, addrSeen, atSeen = {}, {}, {}     -- enemies this game runs: name -> health, address and when, last seen
    local lastPlayed, playedN = {}, 0   -- enemy address -> when an effect was last played on it
    local second, inSecond = 0, 0
    local hooked, triedAt = false, -math.huge
    local playing = false       -- this PC asking its chooser for a partner's hit: the hook isn't this player's then

    local function tagOf(param)
        local s
        pcall(function() s = param:get().TagName:ToString() end)
        return s
    end

    -- What the chooser was asked for here: an attack's hit on something that isn't a player (an enemy, once the mod counts
    -- it). (Lua only: no game call inside the hook.)
    local function note(kind, strength, material)
        if not (kind and strength and material) or kind:sub(1, #TYPE) ~= TYPE or strength:sub(1, #STRENGTH) ~= STRENGTH
            or material:sub(1, #MATERIAL) ~= MATERIAL or material:find("Player", 1, true) then
            return
        end
        if #kept >= MAX_KEPT then
            table.remove(kept, 1)
        end
        kept[#kept + 1] = { t = os.clock(), kind = kind:sub(#TYPE + 1), strength = strength:sub(#STRENGTH + 1),
            material = material:sub(#MATERIAL + 1) }
    end

    -- (A hook on a Blueprint function, which takes no interface parameter: a hook on one with an interface once killed the
    -- host. Hooks on the hit-react component's own calls crashed the bench copy on 11-10: none of those. The hook fires on
    -- the mod's own asks too (hitfx.play): those are a partner's hits, never this player's, and sent back they came twice.)
    local function hook()
        if hooked or os.clock() - triedAt < RETRY_S then
            return
        end
        triedAt = os.clock()
        if not valid(StaticFindObject(CHOOSER_FN)) then
            return
        end
        local ok, err = pcall(RegisterHook, CHOOSER_FN, function(_, kind, strength, material)
            if hitfx.on and not playing and not net.pvp then
                note(tagOf(kind), tagOf(strength), tagOf(material))
            end
        end)
        hooked = ok
        if ok then
            log("Partner hit sounds: this player's hits are watched.")
        else
            triedAt = math.huge
            log("Partner hit sounds: the game's hits can't be watched here (" .. tostring(err) .. ").")
        end
    end

    -- Each enemy's turn (coop.lua syncEnemy): the hook goes in once the game has loaded its chooser, before this player's
    -- first hit.
    function hitfx.ready()
        if hitfx.on and not hooked then
            hook()
        end
    end

    -- A hit of this player's on an enemy, as the mod counts it (a guest's report in coop.lua, a drop seen by hitfx.runs): the
    -- newest effect played here for it, fresh enough, goes to everyone else. id: the enemy's name on the wire (the host's).
    function hitfx.ownHit(id, actor)
        if not hitfx.on or net.pvp or not id then
            return
        end
        hook()
        local r = kept[#kept]
        if r and os.clock() - r.t <= KEEP_S then
            kept[#kept] = nil
            coop.sendEvent("HX", id, r.kind, r.strength, r.material)
            hitfx.sent = hitfx.sent + 1
        end
    end

    -- Each turn of an enemy this game runs (coop.lua: the host's in shareEnemy, a guest's own far from the host in
    -- handover.share): a health drop with one of this player's moves just before is this player's hit. (A partner's blow
    -- written here takes itself off first: see handlers.D below.) theirs: one a guest's game runs that the host's copy
    -- follows, written down to the guest's lines: only noted (the host's hits on it go by reportHit).
    function hitfx.runs(name, actor, addr, hp, theirs)
        if not hitfx.on or net.pvp then
            return
        end
        if not hooked then
            hook()
        end
        local now = os.clock()
        local was = addrSeen[name] == addr and now - (atSeen[name] or -math.huge) <= SEEN_S and hpSeen[name] or nil
        hpSeen[name], addrSeen[name], atSeen[name] = hp, addr, now
        if was and hp < was - 0.5 and not theirs and kept[1] and game.localMoveRecent(OWN_S) then
            hitfx.ownHit(name, actor)
        end
    end

    -- A partner's reported blow (handlers.D, on the host and on a guest for one it runs) lowers the enemy's health here: not
    -- this player's hit, so it comes off what runs() last saw, and only the rest of a drop counts.
    local partnerBlow = coop.handlers.D
    coop.handlers.D = function(rest, from)
        if not hitfx.on or net.pvp then
            return partnerBlow(rest, from)
        end
        local name = (rest or ""):match("^(%S+)")
        local actor = name and coop.enemyActor(name)
        local before = valid(actor) and game.getHealth and game.getHealth(actor) or nil
        partnerBlow(rest, from)
        if before and valid(actor) and addrSeen[name] == actor:GetAddress() and hpSeen[name] then
            local after = game.getHealth(actor)
            if after and after < before then
                hpSeen[name] = hpSeen[name] - (before - after)
            end
        end
    end

    -- Where the blow lands: the body's bone moved toward the hitter, facing away from them (the blood flies on from there).
    local function landing(mesh, bone, from)
        local at = mesh:GetSocketLocation(bone)
        local dx, dy = 1, 0
        if from then
            dx, dy = from.X - at.X, from.Y - at.Y
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 1 then
                dx, dy = 1, 0
            else
                dx, dy = dx / len, dy / len
            end
        end
        return { X = at.X + dx * TOWARD_CM, Y = at.Y + dy * TOWARD_CM, Z = at.Z },
            { Pitch = 0.0, Yaw = math.deg(math.atan(-dy, -dx)), Roll = 0.0 }
    end

    -- The body's own chooser if it has one of the kind that answers GetEffectData (an override, then its own), else the
    -- game's common one. (Others, the dragon pillar's say, are of a class without it.)
    local function chooserOf(comp)
        local base = StaticFindObject(CHOOSER_BASE)
        if not valid(base) then
            if not hitfx.saidNoBase then
                hitfx.saidNoBase = true
                log("Partner hit sounds: the game's hit-effect class isn't here (" .. CHOOSER_BASE .. "): partners' hits stay silent.")
            end
            return nil
        end
        local function fits(c)
            local ok, yes = pcall(function() return valid(c) and c:IsA(base) end)
            return ok and yes
        end
        local c = comp.HitEffectPlayerOverride
        if not fits(c) then
            c = comp.EffectPlayer
        end
        if not fits(c) then
            c = StaticFindObject(CHOOSER)
        end
        return fits(c) and c or nil
    end

    -- The game's own effect for these tags on this body: its sound on it, its blood where the blow lands (from: where the
    -- hitter stands). True if anything played.
    function hitfx.play(actor, kind, strength, material, from)
        if not valid(actor) then
            return false
        end
        local comp = actor:GetComponentByClass(StaticFindObject(HITREACT))
        if not valid(comp) then
            return false
        end
        local chooser = chooserOf(comp)
        if not chooser then
            return false
        end
        local particles, slomo, shake, sound = {}, {}, {}, {}
        playing = true
        local asked = pcall(function()
            chooser:GetEffectData({ TagName = FName(TYPE .. kind) }, { TagName = FName(STRENGTH .. strength) },
                { TagName = FName(MATERIAL .. material) }, particles, slomo, shake, sound)
        end)
        playing = false
        if not asked then
            return false
        end
        local played = false
        local ev, ak = sound.HitSound, StaticFindObject(AK)
        if valid(ev) and valid(ak) then
            played = pcall(function() ak:PostEvent(ev, actor, 0, {}, false) end)
        end
        local list, n = particles.Particles, 0
        pcall(function() n = #list end)
        local mesh, niagara = actor.Mesh, StaticFindObject(NIAGARA)
        if n > 0 and valid(mesh) and valid(niagara) then
            local body = {}
            pcall(function() comp:GetMainBodyData(body) end)
            local bone = body.bone
            local okAt, where, turn = false, nil, nil
            if bone ~= nil then
                okAt, where, turn = pcall(landing, mesh, bone, from)
            end
            for i = 1, okAt and math.min(n, MAX_BLOOD) or 0 do
                pcall(function()
                    local e = list[i]
                    e = (type(e) == "userdata" and e.get) and e:get() or e
                    local system = e.Particle
                    if valid(system) then
                        niagara:SpawnSystemAttached(system, mesh, bone, where, turn, 1, true, true, 0, true)
                        played = true
                    end
                end)
            end
        end
        return played
    end

    local function sane(s, pattern)
        return s ~= nil and #s <= 80 and s:match(pattern) ~= nil
    end

    -- A partner's hit on an enemy: the same effect here, on this PC's copy of it.
    coop.handlers.HX = function(rest, from)
        if not hitfx.on or net.pvp or os.clock() < (net.quietUntil or 0) then
            return
        end
        local id, kind, strength, material = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+)$")
        if not (id and sane(kind, "^[%w_%.]+$") and sane(strength, "^[%w_%.]+$") and sane(material, "^[%w_]+$")) then
            hitfx.refused = hitfx.refused + 1
            return
        end
        local now = os.clock()
        if now - second >= 1 then
            second, inSecond = now, 0
        end
        if inSecond >= MAX_PER_S then
            hitfx.refused = hitfx.refused + 1
            return
        end
        local actor = coop.enemyActor(id)
        if not valid(actor) then
            return
        end
        local addr = actor:GetAddress()
        if now - (lastPlayed[addr] or -math.huge) < GAP_S then
            return
        end
        local at = actor:K2_GetActorLocation()
        local pawn = coop.localPawn()
        local here = valid(pawn) and pawn:K2_GetActorLocation() or nil
        if here and (at.X - here.X) ^ 2 + (at.Y - here.Y) ^ 2 + (at.Z - here.Z) ^ 2 > HEAR_CM * HEAR_CM then
            return
        end
        local p = coop.peerOf(from)
        local figure = p and p.ghost
        inSecond = inSecond + 1
        if playedN > 200 then
            lastPlayed, playedN = {}, 0
        end
        lastPlayed[addr], playedN = now, playedN + 1
        if hitfx.play(actor, kind, strength, material, valid(figure) and figure:K2_GetActorLocation() or here) then
            hitfx.played = hitfx.played + 1
        end
    end

    -- Someone started sync anew: what this game saw before is no measure of what comes.
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(...)
        kept, hpSeen, addrSeen, atSeen = {}, {}, {}, {}
        return syncStarted(...)
    end

    -- hitsounds on | off   (read at start from PartnerHitSounds)
    function hitfx.command(args)
        local v = (args or ""):lower():match("^%s*(%a+)")
        if v == "on" or v == "off" then
            hitfx.on = v == "on"
        end
        log(string.format("Partner hit sounds: %s", hitfx.on
            and "on (a partner's hits on enemies play the game's hit sound and blood here)." or "off."))
    end

    return hitfx
end
