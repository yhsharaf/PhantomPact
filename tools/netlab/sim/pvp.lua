-- A whole PvP match in the simulator, two players, "here" (no trip): lobby, start, rounds, the end, the finishing move,
-- home; then a second match a guest leaves. python -I tools/netlab/luasim.py pvp
local Session = dofile(SIM_DIR .. "/session.lua")
local Fake = Session.Fake

return function(out, scripts)
    local failed = 0
    local function check(ok, what)
        out("  " .. (ok and "ok   " or "FAIL ") .. what)
        if not ok then failed = failed + 1 end
    end
    local function count(list, pattern)
        local n = 0
        for _, line in ipairs(list) do
            if line:find(pattern) then n = n + 1 end
        end
        return n
    end
    local function last(list, pattern)
        for i = #list, 1, -1 do
            if list[i]:find(pattern) then return list[i] end
        end
        return "-"
    end
    local function countFrom(list, from, pattern)
        local n = 0
        for i = from + 1, #list do
            if list[i]:find(pattern) then n = n + 1 end
        end
        return n
    end
    -- The match's gourd as the game has it: drinks/size and level.
    local function gourd(pc)
        local f = rawget(pc.gourd, "__fields")
        return string.format("%s/%s level %s", tostring(f.CurrentTime), tostring(f.MaxTime), tostring(f.CurrentLevel))
    end

    out("the finishing move a place gets (arenas.lua):")
    do
        local data = dofile(scripts .. "/arenas.lua")
        for place, a in ipairs(data.arenas) do
            local f = data.FINISHERS[data.finisherFor(place)]
            check(f and f.boss == a.key, a.name .. ": its boss's own move (" .. tostring(f and f.key) .. ")")
        end
        local seen, rouge = {}, 0
        for _ = 1, 60 do
            local f = data.FINISHERS[data.finisherFor(0)]
            seen[f.key] = true
            rouge = rouge + (f.boss and 0 or 1)
        end
        local kinds = 0
        for _ in pairs(seen) do kinds = kinds + 1 end
        check(rouge == 0 and kinds >= 3, "here: one of the bosses' moves drawn (" .. kinds .. " of 4 in 60 draws, never the Rouge's)")
        check(data.FINISHERS[1].key == "rouge" and not data.FINISHERS[1].lead, "the Rouge's close-in execution stays first")
    end

    local s = Session.new(scripts, { "Host", "Guest" }, false,
        { { "near", "BP_Monster_MaleThug_Sword_Blue_C", 300.0, 0.0, 100.0, 850, 400, false } }, nil)
    local h, g = s.pcs[1], s.pcs[2]
    s:run(4)
    Session.moveTo(h, 0, 0)
    Session.moveTo(g, 500, 0)
    s:run(2)
    local ha, ga = h.env.PBZ.arena, g.env.PBZ.arena
    check(ha ~= nil and ga ~= nil, "both have the arena module")

    out("which boss arenas a save opens (its spawners' records, SpawnerSaveData):")
    do
        local data = dofile(scripts .. "/arenas.lua")
        local yc, mxk
        for _, a in ipairs(data.arenas) do
            if a.key == "yucong" then yc = a elseif a.key == "muxiaokui" then mxk = a end
        end
        check(yc and #yc.unlock == 3 and mxk and #mxk.unlock == 1, "YuCong lists his last phase's three bodies, Mu Xiaokui one")
        -- The world's records as the game's TMap hands them over: a key, and a record with IsAlive.
        local records = {}
        local saves = { IsValid = function() return true end, SpawnerSaveData = { ForEach = function(_, fn)
            for key, alive in pairs(records) do
                fn({ get = function() return key end }, { get = function() return { IsAlive = alive } end })
            end
        end } }
        local find = h.env.FindFirstOf
        h.env.FindFirstOf = function(class)
            if class == "PBZAISaveGameWorldSubsystem" then
                return saves
            end
            return find(class)
        end
        records[yc.unlock[1]], records[yc.unlock[2]] = true, true
        check(not ha.readUnlocked().yucong, "his bodies alive: not open")
        records[yc.unlock[2]] = false
        check(ha.readUnlocked().yucong == true, "one of his last phase's bodies dead: open")
        records[mxk.unlock[1]] = false
        check(ha.readUnlocked().muxiaokui == true, "a boss of one listed spawner opens on it (Mu Xiaokui)")
        ha.refused = { yucong = true }
        check(not ha.readUnlocked().yucong and ha.unlocked.muxiaokui == true,
            "an arena this world showed unfinished stays closed this session, the others open")
        ha.refused = nil
        h.env.FindFirstOf = find
        ha.readUnlocked()
        check(next(ha.unlocked) == nil, "no records: none open (the sim's world, as before)")
        check(ha.storyBegan ~= nil and ha.storyBegan({ place = 1, phase = "count" }, true) == false,
            "a match this player isn't in: nothing called off")
    end
    -- Their skill trees, as the game has them: the host bought three nodes, one of them a talisman slot's; the guest none.
    local OWN = "HeiShi1,HeiShi2,MemoryFlower1"
    local all = #Fake.tree(h, { "HeiShi1", "HeiShi2", "MemoryFlower1" })
    Fake.tree(g, {})
    -- The host wears a talisman in its first slot (the bag's AssemblyAccessory: a name a slot, "None" in an empty one), its
    -- one slot open by HeiShi2; the game's own calls on them, in order.
    local hList, talismanCalls = { "AC_Deflect", "None", "None", "None" }, {}
    local function openSlots()
        local n = 0
        for _ in pairs(h.slots) do
            n = n + 1
        end
        return n
    end
    Fake.put(h.bag, "AssemblyAccessory", { ForEach = function(_, fn)
        for i, id in ipairs(hList) do
            fn(i, { get = function() return h.env.FName(id) end })
        end
    end })
    Fake.put(h.bag, "GetCanAssembleAccessoryNum", openSlots)
    Fake.put(h.bag, "TakeOffAccessory", function(_, slot)
        talismanCalls[#talismanCalls + 1] = "off " .. slot
        hList[slot + 1] = "None"
    end)
    Fake.put(h.bag, "AssembleAccessory", function(_, id, slot)
        talismanCalls[#talismanCalls + 1] = string.format("on %s %d (%d open)", id:ToString(), slot, openSlots())
        hList[slot + 1] = id:ToString()
    end)
    local function onNodes(pc)
        local ids = {}
        for id in pairs(pc.treeOn) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        return table.concat(ids, ",")
    end
    local function onCount(pc)
        local n = 0
        for _ in pairs(pc.treeOn) do
            n = n + 1
        end
        return n
    end
    local function attack(pc)
        local ok, v = pcall(function() return pc.pawn.AttributeSetBase.Attack.CurrentValue end)
        return ok and v or -1
    end
    local attack0 = attack(h)
    -- 66 Days' perfect deflect window in this player's game (its combat config; difficulty.lua).
    local function daysWindow(pc)
        local c = pc.combatConfigs and pc.combatConfigs.Nightmare
        return c and rawget(c, "__fields")["Deflect Perfect Window Frames"] or 6
    end

    out("the game's difficulty, the same for everyone in a match:")
    h.difficulty = 4                            -- (the host plays 66 Days)
    Session.command(g, "difficulty off")        -- (the guest keeps its own mode with a partner, Wayfarer)
    s:run(1.5)
    g.difficulty = 1                            -- (picked once the setting is off: nothing holds it)
    s:run(1.5)
    check(h.difficulty == 4 and g.difficulty == 1, "before the match: the host on 66 Days, the guest on its own Wayfarer: "
        .. h.difficulty .. "/" .. g.difficulty)

    out("lobby:")
    Session.command(h, "arena place 0")
    Session.command(g, "arena ready")
    s:run(1.5)
    check(count(h.sent, "^E AR lobby") >= 1, "the host tells the lobby")
    check(count(g.sent, "^E AR pick") >= 1, "the guest's pick goes out")
    check(ha.picks[2] and ha.picks[2].ready == true, "the host has the guest ready")
    check(ga.lobby ~= nil and ga.lobby.place == 0, "the guest has the lobby (here)")
    check(ha.blocker() == nil, "nothing stops the start: " .. tostring(ha.blocker()))

    out("start:")
    Fake.setHealth(h.pawn, 600)         -- (the host's health before the match: given back at home, no free heal)
    local gourd0 = gourd(h)
    Session.command(h, "arena start")
    s:run(2)
    local sentBefore = #h.sent
    check(ha.match ~= nil and ga.match ~= nil, "both are in the match")
    check(h.env.PBZ.net.arena == true and g.env.PBZ.net.arena == true, "both trim the network (net.arena)")
    check(h.env.PBZ.net.pvp == true and g.env.PBZ.net.pvp == true, "both fight (net.pvp)")
    s:run(3)
    check(g.difficulty == 3 and g.files["difficulty_own.txt"] == nil,
        "in the match the guest's Wayfarer is Hellwalker, CoopDifficulty off or not (no file: a match is never saved): "
        .. g.difficulty .. ", " .. tostring(g.files["difficulty_own.txt"]))
    check(h.difficulty == 4 and daysWindow(h) == 8, "the host stays on 66 Days, with Hellwalker's 8-frame perfect deflect: "
        .. h.difficulty .. ", " .. daysWindow(h))
    local hm, gm = ha.match, ga.match
    check(hm and gm and hm.id == gm.id, "the same match on both")
    check(hm and (hm.phase == "count" or hm.phase == "fight"), "the host counts down or fights: " .. tostring(hm and hm.phase))
    check(gm and (gm.phase == "count" or gm.phase == "fight"), "the guest counts down or fights: " .. tostring(gm and gm.phase))
    s:run(3.5)
    check(hm and hm.phase == "fight" and gm.phase == "fight", "the fight is on: " .. tostring(hm and hm.phase) .. "/" ..
        tostring(gm and gm.phase))
    check(onCount(h) == all and onCount(g) == all, "every skill node on for both: " .. onCount(h) .. "/" .. onCount(g))
    check(table.concat(hList, ",") == "None,None,None,None" and talismanCalls[1] == "off 0",
        "the host's talisman off for the match, by its slot: " .. table.concat(hList, ","))
    check((h.files["pvp_restore.txt"] or ""):find("worn = 0:AC_Deflect", 1, true) ~= nil, "the journal has it, by slot")
    hList[3] = "AC_PowerWeapon_2"           -- (one put on during the match, in a slot the match opened)
    s:run(2.5)
    check(hList[3] == "None" and talismanCalls[#talismanCalls] == "off 2", "one put on in the match comes off again")
    local enemyEvents = 0
    for i = sentBefore + 1, #h.sent do
        local line = h.sent[i]
        if line:find("^E [KNBF] ") or line:find("^Q A ") or line:find("^N ") or line:find("^Q NQ ") then
            enemyEvents = enemyEvents + 1
        end
    end
    check(enemyEvents == 0, "no enemy traffic from the host in the match: " .. enemyEvents)
    for i = sentBefore + 1, #h.sent do
        local line = h.sent[i]
        if line:find("^E [KNBF] ") or line:find("^Q A ") or line:find("^N ") or line:find("^Q NQ ") then
            out("    enemy traffic: " .. line:sub(1, 120))
        end
    end

    out("the gourd, the same for everyone:")
    check(gourd(h) == "3/3 level 6" and gourd(g) == "3/3 level 6",
        "3 drinks in a gourd of 3, at its top level, for both: " .. gourd(h) .. ", " .. gourd(g))
    Fake.put(h.gourd, "CurrentTime", 2)         -- (the host drinks)
    s:run(1.5)
    Fake.put(h.gourd, "CurrentTime", 3)         -- (and the gourd fills again: a bell's sit does)
    s:run(1.5)
    check(gourd(h) == "2/3 level 6", "a drink stays drunk: a refill in the match is taken back: " .. gourd(h))
    -- (The extra drink a skill node gives would be a fourth, and it stayed after the match: the bench, 11-09.)
    local hb, gb = rawget(h.bag, "__fields"), rawget(g.bag, "__fields")
    check(hb.MedicineExtraUsage == 0 and gb.MedicineExtraUsage == 0,
        "no extra drink in the match, the node's taken off: " .. hb.MedicineExtraUsage .. "/" .. gb.MedicineExtraUsage)
    check((h.files["pvp_restore.txt"] or ""):find("extra = 1", 1, true) ~= nil
        and (h.files["pvp_restore.txt"] or ""):find("charges = 1 40.00", 1, true) ~= nil,
        "the journal has the extra drink and the Combat Art's charges as they were")
    -- (Q did nothing in a match: no charges, and blows on a figure build none; the bench, 11-09.)
    check(hb.ult.n == 3 and gb.ult.n == 3, "the Combat Art full for both at the round's start: " .. hb.ult.n .. "/" .. gb.ult.n)
    hb.ult.n, gb.ult.n = 1, 0      -- (both spend some)

    out("a gap in the match (a loading screen's worth): the world's news waits for the end:")
    h.env.PBZ.net.deadSent["sp:dead1"] = true   -- (an enemy dead before the match, told then)
    local sentGap = #h.sent
    g.cut = true
    s:run(4)
    g.cut = false
    s:run(4)
    check(countFrom(h.sent, sentGap, "^E [KB] ") == 0,
        "nothing of the dead or the bosses told again in the match: " .. countFrom(h.sent, sentGap, "^E [KB] "))
    check(ha.match and ga.match and ha.match.phase == "fight", "and the match goes on after it")

    out("parries, judged by the game's own deflect:")
    -- The guest swings at the host beside it, and the host's game answers with its guard or doesn't. (The bench, 11-07: a
    -- guard pressed as the blow comes plays Hun_Tang_DefenceNormal_* and costs nothing; one held from before it plays the
    -- same and costs nothing either; a blow that never reached, nothing. Every figure always runs
    -- GA_Hun_ShachiHook_Passive_C.)
    local DEFENCE = "/PBZCombatAsset/ActorData/Move/Hun_Tang_DefenceNormal_B_Montage.Hun_Tang_DefenceNormal_B_Montage"
    local function figureMontage()
        local ok, path = pcall(function()
            return rawget(rawget(rawget(g.env.PBZ.net.ghost, "__fields").anim, "__fields").montage, "__path")
        end)
        return ok and path or "-"
    end
    local STANCE = "GA_Hun_Tang_Stance_C"
    local STANCE_ENTER = "/PBZCombatAsset/ActorData/Move/AM_Hun_Tang_StanceEnter.AM_Hun_Tang_StanceEnter"
    local heldSeen = "-"            -- the host's figure, for the guest, as the held guard went up
    local hgame = h.env.PBZ.game
    -- The guest cm along X from the host, facing it (yaw 180), or away (its move aimed elsewhere).
    local function beside(cm, away)
        local l = rawget(h.pawn, "__fields").loc
        Session.moveTo(g, l.X + cm, l.Y, l.Z)
        Fake.put(g.pawn, "yaw", away and 0.0 or 180.0)
        s:run(1.0)
    end
    -- The guest's blow (its attack's ability on: the guest's own watch sends it as M) and the host's guard: "parry" raised as
    -- it comes, "held" up from before it, "block" raised as it comes but taken out of the host's posture, "none" no answer.
    local function blow(how)
        if how == "held" then
            Fake.running(h, h.pawn, STANCE, true)
            Session.startMove(h, STANCE_ENTER)
            s:run(0.5)
            heldSeen = figureMontage()
        end
        Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", true)
        s:run(0.15)
        if how == "parry" or how == "block" then
            Fake.running(h, h.pawn, STANCE, true)
        end
        s:run(0.1)
        if how ~= "none" then
            if how == "block" then
                hgame.setPosture(h.pawn, hgame.getPosture(h.pawn) - 170)
            end
            Session.startMove(h, DEFENCE)
        end
        s:run(0.4)
        Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", false)
        Fake.running(h, h.pawn, STANCE, false)
        Session.endMove(h)
        s:run(1.6)
    end
    local function parries()
        return count(h.sent, "^E V parry")
    end
    Fake.running(g, g.pawn, "GA_Hun_ShachiHook_Passive_C", true)       -- (on for good, as the game's are)
    beside(150)
    blow("parry")
    check(parries() == 1, "a deflect (the guard raised to meet the blow, nothing lost) is a parry, at once: " .. parries())
    check(count(g.logs, "PARRIED you") == 1, "the guest staggers for it: " .. count(g.logs, "PARRIED you"))
    check(count(h.sent, "^%u U .*DefenceNormal") >= 1, "the host's guard answer goes out in the match")
    check(tostring(figureMontage()):find("DefenceNormal", 1, true) ~= nil,
        "and the host's figure plays it for the guest: " .. tostring(figureMontage()))
    blow("held")
    check(parries() == 1, "a guard held from before the blow only blocks, no stagger: " .. parries())
    check(tostring(heldSeen):find("StanceEnter", 1, true) ~= nil,
        "the guard going up goes out in the match and the host's figure raises it for the guest: " .. tostring(heldSeen))
    check(count(h.sent, "^%u U ") == count(h.sent, "^%u U .*Defence") + count(h.sent, "^%u U .*Stance"),
        "no move but the guard's goes out as U in a match")
    -- Held through the blow and on after it: the figure goes back into the guard, as the host's own body does.
    local function figureShields()
        return rawget(rawget(g.env.PBZ.net.ghost, "__fields"), "effects") or 0
    end
    local shieldsBefore = figureShields()
    Fake.running(h, h.pawn, STANCE, true)
    Session.startMove(h, STANCE_ENTER)
    s:run(0.6)
    local shieldsUp = figureShields()
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", true)
    s:run(0.25)
    Session.startMove(h, DEFENCE)
    s:run(0.3)
    local during = figureMontage()
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", false)
    Session.endMove(h)
    s:run(1.6)
    local after = figureMontage()
    Fake.running(h, h.pawn, STANCE, false)
    s:run(1.5)
    check(shieldsUp == shieldsBefore + 1 and figureShields() == shieldsBefore,
        string.format("the host's figure shielded for the guest while the guard is up, so the guest's blows don't flinch it (%d, %d, %d)",
            shieldsBefore, shieldsUp, figureShields()))
    check(during:find("Defence", 1, true) ~= nil and after:find("StanceEnter", 1, true) ~= nil,
        "a guard held on after its answer to a blow: the figure turns the blow aside, then stands in the guard again: "
        .. during:match("[^.]+$") .. " then " .. after:match("[^.]+$"))
    blow("block")
    check(parries() == 1, "nor a guard answer that cost posture: " .. parries())
    blow("none")
    check(parries() == 1, "nor a blow that never reached the host: " .. parries())
    Session.startMove(h, DEFENCE)
    s:run(0.5)
    Session.endMove(h)
    s:run(1.6)
    check(parries() == 1, "nor a guard answer with no attack of the guest's (its always-on passive isn't one): " .. parries())
    beside(600)
    blow("parry")
    check(parries() == 1, "nor a deflect of a foe out of reach: " .. parries())
    -- (In PvPvE an enemy's blow turned aside while the partner swung nearby, at something else, staggered the partner.)
    beside(150, true)
    blow("parry")
    check(parries() == 1, "nor a deflect while the guest's move was aimed away from the host (another's blow): " .. parries())
    beside(150)
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", true)
    s:run(0.01)
    Fake.running(h, h.pawn, STANCE, true)
    Session.startMove(h, DEFENCE)
    s:run(0.4)
    Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", false)
    Fake.running(h, h.pawn, STANCE, false)
    Session.endMove(h)
    s:run(1.6)
    check(parries() == 1, "nor a guard answer as the guest's move began, before its blow could have come: " .. parries())
    blow("parry")
    check(parries() == 2, "and the next deflect in reach, facing the host, is one again: " .. parries())
    -- One press, at the right time (a player's ask, 11-09): not long before the blow, nor a click after one that met nothing.
    local function slowBlow(pressAt, defenceAt)         -- (seconds after the guest's attack begins)
        Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", true)
        s:run(pressAt)
        Fake.running(h, h.pawn, STANCE, true)
        s:run(defenceAt - pressAt)
        Session.startMove(h, DEFENCE)
        s:run(0.4)
        Fake.running(g, g.pawn, "GA_Hun_Tang_A_C", false)
        Fake.running(h, h.pawn, STANCE, false)
        Session.endMove(h)
        s:run(1.6)
    end
    slowBlow(0.05, 0.75)
    check(parries() == 2, "pressed as a slow blow's move began, 0.7 s before it came: a block, no stagger: " .. parries())
    slowBlow(0.6, 0.75)
    check(parries() == 3, "pressed just before it came (0.15 s): a parry: " .. parries())
    for _ = 1, 3 do                 -- (clicks at random, none meeting a blow)
        Fake.running(h, h.pawn, STANCE, true)
        s:run(0.1)
        Fake.running(h, h.pawn, STANCE, false)
        s:run(0.15)
    end
    blow("parry")
    check(parries() == 3, "a timed press right after clicks that met nothing: only a block: " .. parries())
    blow("parry")
    check(parries() == 4, "the next timed press, after one that met a blow, is a parry again: " .. parries())
    Fake.running(g, g.pawn, "GA_Hun_ShachiHook_Passive_C", false)

    out("a foe's Phantom Edge on their figure:")
    -- (A figure is made from this PC's bag, so in a match its Phantom Edge was this player's own, and its abilities, which run
    -- for real in PvP, drew that one. The guest had none before the match, "E -", and the host hid its figure's.)
    local CANNON, HOOK = "/PBZCombatAsset/ActorData/Weapon/Cannon.Cannon", "/PBZCombatAsset/ActorData/Weapon/Hook.Hook"
    local function figureGear()
        return rawget(rawget(h.env.PBZ.net.ghost, "__fields"), "Character Weapons Component")
    end
    local function gearField(name)
        return rawget(rawget(figureGear(), "__fields"), name)
    end
    local function figureEdge()
        local cfg = gearField("edgeConfig")
        return cfg and tostring(rawget(cfg, "__path")):match("[^.]+$") or "-"
    end
    Fake.put(figureGear(), "edgeConfig", h.env.StaticFindObject(HOOK))     -- (the host's own, from its bag)
    Session.holdEdge(g, CANNON, false)
    s:run(1.5)
    check(figureEdge() == "Cannon", "the guest's figure on the host's screen holds the guest's Phantom Edge, not the host's: "
        .. figureEdge())
    check(gearField("edgeHidden") ~= true, "and shows it: not still hidden from before the match")
    Session.holdEdge(g, CANNON, true)
    s:run(1)
    check(gearField("edgeArmed") ~= true, "the guest's word doesn't draw it on the figure: in PvP its own abilities do")
    Fake.put(figureGear(), "edgeArmed", true)          -- (its own ability drew it as the guest's skill began)
    Session.holdEdge(g, HOOK, true)
    Session.edgeMove(g, "/PBZCombatAsset/ActorData/Move/Show.Show")
    s:run(1)
    check(figureEdge() == "Cannon" and gearField("edgeArmed") == true,
        "changed while drawn: the skill on the figure keeps its weapon, and nothing puts it away under it")
    check(count(g.sent, "^%u Z ") == 0, "no Z in a match: the figure's own ability plays its weapon's moves")
    Fake.put(figureGear(), "edgeArmed", false)         -- (the skill over: its ability put it away)
    Session.holdEdge(g, HOOK, false)
    s:run(1)
    check(figureEdge() == "Hook", "put away, the figure takes the one the guest holds now: " .. figureEdge())
    Fake.put(rawget(g.pawn, "__fields").edgeAnim, "montage", nil)
    Fake.put(rawget(g.pawn, "__fields")["Character Weapons Component"], "edgeConfig", nil)     -- (none again)
    -- Its skills: GA_<edge>_*, not Hun's (the bench, 11-08: GA_BrutalAxe_Normal_C was never sent, so its blow never landed).
    local edgeSent = count(g.sent, "^%u M .*GA_BrutalAxe_Normal")
    Fake.running(g, g.pawn, "GA_BrutalAxe_Normal_C", true)
    Fake.running(g, g.pawn, "GA_Talent_EnableTenacity_C", true)
    Fake.running(g, g.pawn, "GA_BrutalAxe_Execution_C", true)
    s:run(0.3)
    Fake.running(g, g.pawn, "GA_BrutalAxe_Normal_C", false)
    Fake.running(g, g.pawn, "GA_Talent_EnableTenacity_C", false)
    Fake.running(g, g.pawn, "GA_BrutalAxe_Execution_C", false)
    s:run(0.5)
    check(count(g.sent, "^%u M .*GA_BrutalAxe_Normal") == edgeSent + 1,
        "a Phantom Edge's skill goes out as a move in a match: " .. (count(g.sent, "^%u M .*GA_BrutalAxe_Normal") - edgeSent))
    check(count(g.sent, "^%u M .*GA_Talent") == 0 and count(g.sent, "^%u M .*Execution") == 0,
        "nor a talent nor an execution: " .. count(g.sent, "^%u M .*GA_Talent") .. ", " .. count(g.sent, "^%u M .*Execution"))

    out("the host on the guest's boss bar: its posture strip, and its figure made again:")
    do
        -- The fake HUD lists no bars (GetBossHPBarInstances is {}): here it makes one widget an actor, as the game's
        -- RegisterBossHandles keeps them, and only UnRegisterBossHPBar drops one (a clone put away is never destroyed, so
        -- the game's OnBossActorDestroyed never comes for it).
        local hud = g.hudLayout
        local f = rawget(hud, "__fields")
        local realUp, realDown, realList = f.RegisterBossHPBar, f.UnRegisterBossHPBar, f.GetBossHPBarInstances
        local up, bars = {}, {}
        local function field(o, k)
            return o and rawget(rawget(o, "__fields"), k)
        end
        Fake.put(hud, "RegisterBossHPBar", function(self, b)
            local a = b:GetAddress()
            if not up[a] then
                local strip = Fake.object(g, "PBZAnimProgressBar_C", { shown = true }, true)
                Fake.put(strip, "SetVisibility", function(st, v) Fake.put(st, "shown", v ~= 1 and v ~= 2) end)
                local bar = Fake.object(g, "WB_BossHPBar_C", { BreakmeterBar = strip, shachi = 1.0,
                    BossName = Fake.object(g, "PBZCommonLocText", {}, true) }, true)
                Fake.put(bar, "ForSeq_UpdateShachi", function(w, v) Fake.put(w, "shachi", v) end)
                up[a] = bar
                bars[#bars + 1] = bar
            end
            return realUp(self, b)
        end)
        Fake.put(hud, "UnRegisterBossHPBar", function(self, b)
            local a = b:GetAddress()
            for i = #bars, 1, -1 do
                if bars[i] == up[a] then
                    table.remove(bars, i)
                end
            end
            up[a] = nil
            return realDown(self, b)
        end)
        Fake.put(hud, "GetBossHPBarInstances", function()
            local list = {}
            for i, bar in ipairs(bars) do
                list[i] = { get = function() return bar end }
            end
            return list
        end)
        s:run(2)                                    -- (no bar found: the guest's tick puts it up again, now one)
        local net = g.env.PBZ.net
        local old = net.ghost
        local oldAddr = old and old:GetAddress()
        local bar = oldAddr and up[oldAddr]
        check(bar ~= nil and #bars == 1, "the host's figure on the game's boss bar: " .. #bars)
        hgame.setPosture(h.pawn, 320)               -- (half the match's 640: blows, a parry)
        s:run(1)
        local share = net.postureShare
        check(share ~= nil and math.abs(share - 0.5) < 0.02, "the host's posture comes with its place: " .. tostring(share))
        check(math.abs((field(bar, "shachi") or -1) - 0.5) < 0.02 and field(field(bar, "BreakmeterBar"), "shown") == true,
            "and moves the gold strip under the host's health: " .. tostring(field(bar, "shachi")))
        hgame.setPosture(h.pawn, 640)
        -- The figure made again, the old one put away and not taken back: a new body (a trip, a party's change).
        local unpark = net.unparkClone
        net.unparkClone = function() return nil end
        Session.command(g, "ghost clone")
        s:run(3)
        net.unparkClone = unpark
        local newAddr = net.ghost and net.ghost:GetAddress()
        check(newAddr ~= nil and newAddr ~= oldAddr and old:IsValid(), "a new figure, the old one put away, still there")
        check(up[oldAddr] == nil, "the old figure's bar taken down, not left up frozen")
        check(g.env.PBZ.game.foeBar(oldAddr) == nil, "and its address no foe's any more (a boss given it later is a boss)")
        check(newAddr ~= nil and up[newAddr] ~= nil and #bars == 1, "one bar, the new figure's: " .. #bars)
        Fake.put(hud, "RegisterBossHPBar", realUp)
        Fake.put(hud, "UnRegisterBossHPBar", realDown)
        Fake.put(hud, "GetBossHPBarInstances", realList)
    end

    out("round 1, the guest goes down:")
    -- (As a real blow leaves a player: at the floor's 1, the game's own bar empty and its near-death look on.)
    Fake.setHealth(g.pawn, 1)
    local bellSteps, sits = count(g.trace, "Bell RestoreHealth"), count(g.sent, "^E SIT")
    -- The game's drink tip (W_TutorialBar_Hint_Potion_C), made by the game only as it first shows the tip in a game, a
    -- moment after the blow: here the frame after the guest's world hid the tip as it fell (the bench, 11-07 20:13).
    local tip = { __alive = true, opacity = 1.0 }
    function tip.IsValid() return true end
    function tip.GetClass(self) return self end
    function tip.GetFName() return Fake.name("W_TutorialBar_Hint_Potion_C") end
    function tip.SetRenderOpacity(self, v) self.opacity = v end
    local tipSearches, findAll = 0, g.env.FindAllOf
    g.env.FindAllOf = function(class)
        if class == "W_TutorialBar_Hint_Potion_C" then
            tipSearches = tipSearches + 1
        end
        return findAll(class)
    end
    Session.command(g, "arena down")
    s:run(1, function()
        if gm.hintHidden and not tip.made then
            tip.made = true
            g.spawned[#g.spawned + 1] = tip
        end
    end)
    check(tip.made and tip.opacity == 0.0, "the game's drink tip, made after the guest's world hid it as it fell, is hidden too: "
        .. tostring(tip.opacity))
    check(count(g.sent, "^E AR down") == 1, "the guest says it's down")
    check(hm.score[1] == 1 and hm.score[2] == 0, "the host scores it 1 - 0: " .. hm.score[1] .. " - " .. hm.score[2])
    check(gm.score[1] == 1, "the guest hears the score")
    s:run(4.5)
    check(hm.round == 2 and gm.round == 2, "round 2 counts down: " .. hm.round .. "/" .. gm.round)
    check(rawget(h.bag, "__fields").ult.n == 3 and rawget(g.bag, "__fields").ult.n == 3,
        "the Combat Art full again for round 2, as the health")
    check(tip.opacity == 1.0 and tipSearches <= 8, string.format(
        "the tip back for round 2, looked for about once a second while the guest was down: %s, %d searches",
        tostring(tip.opacity), tipSearches))
    -- (Written by hand, the refill left the bar empty and the near-death look on till a blow: the bench, 11-07.)
    local ghp, gmax = Fake.health(g.pawn)
    check(math.abs(ghp - gmax) < 0.5 and count(g.trace, "Bell RestoreHealth") > bellSteps,
        string.format("round 2: the guest filled the game's way, %.0f of %.0f (%s; the sim's effects heal nobody)", ghp, gmax,
            tostring(g.env.PBZ.game.refillHow)))
    check(count(g.sent, "^E SIT") == sits and count(g.logs, "rested at a bell") == 0, "a refill, not a sit: no SIT, no forfeit")
    s:run(3.5)
    check(hm.phase == "fight" and gm.phase == "fight", "round 2 is on")

    out("round 2, the host goes down:")
    Session.command(h, "arena down")
    s:run(1)
    check(hm.score[2] == 1 and gm.score[2] == 1, "1 - 1 on both")
    s:run(8)
    check(hm.round == 3 and hm.phase == "fight", "round 3 is on: " .. hm.round .. " " .. hm.phase)

    out("round 3 and the end:")
    Session.command(g, "arena down")
    s:run(1)
    check(hm.score[1] == 2, "2 - 1 to Crimson (the host)")
    s:run(3)
    check(hm.phase == "finish" and gm.phase == "finish", "the finishing window: " .. hm.phase .. "/" .. gm.phase)
    Session.command(h, "arena finish 2 2")
    s:run(1)
    check(count(h.sent, "^E AR fin") == 1, "the host finishes the guest: " .. last(h.sent, "^E AR fin"))
    check(gm.finished == 2, "the guest's world knows it's the one finished")
    check(count(g.logs, "finishes") == 1 and count(h.logs, "finishes") == 1, "both worlds play the move")
    local clock = (h.env.os and h.env.os.clock) or os.clock
    check(hm.finishUntil > clock() + 2, "the result waits for the move: " .. string.format("%.1f s", hm.finishUntil - clock()))
    -- Again (issue #13): the host's F from a moment into the last screens (arena.again, what F calls), a rematch where
    -- they stand: round 1 at 0 - 0, nothing of the match's setup done twice, the trip home after the last match.
    out("again, from the last screens:")
    for _ = 1, 240 do
        if hm.phase ~= "finish" then
            break
        end
        s:run(0.05)
    end
    check(hm.phase == "result" and ha.again() == false and count(h.sent, "^E AR again") == 0,
        "not as the last screens come (a finishing blow's F held on isn't one): " .. tostring(ha.match and ha.match.phase))
    s:run(1.6)
    check(ga.again() == false and count(g.sent, "^E AR again") == 0, "the guest can't call it")
    local againFrom = #h.sent
    Fake.setHealth(g.pawn, 1)           -- (as a finishing move leaves the beaten)
    check(hm.phase == "result" and ha.again() == true, "the host can, 1.5 s in (now: " .. tostring(hm.phase) .. ")")
    s:run(0.5)
    check(countFrom(h.sent, againFrom, "^E AR again") == 1, "told once: " .. last(h.sent, "^E AR again"))
    check(hm.phase == "count" and gm.phase == "count" and hm.round == 1 and gm.round == 1, string.format(
        "round 1 counts down on both: %s %d / %s %d", hm.phase, hm.round, gm.phase, gm.round))
    check(hm.score[1] == 0 and hm.score[2] == 0 and gm.score[1] == 0 and gm.score[2] == 0, "at 0 - 0 on both")
    check(gm.finished == nil and hm.winner == nil and gm.winner == nil and not gm.down[2], "the last match's end forgotten")
    check(gourd(h) == "3/3 level 6" and gourd(g) == "3/3 level 6",
        "the gourd's 3 drinks back for both (the host drank one): " .. gourd(h) .. ", " .. gourd(g))
    local againHp, againMax = Fake.health(g.pawn)
    check(math.abs(againHp - againMax) < 0.5, string.format("the guest, finished, up and whole: %.0f of %.0f", againHp, againMax))
    check(h.env.PBZ.net.arena == true and g.env.PBZ.net.pvp == true and g.difficulty == 3,
        "still the match's network and Hellwalker: no trip home between")
    check((h.files["pvp_restore.txt"] or ""):find("worn = 0:AC_Deflect", 1, true) ~= nil
        and (h.files["pvp_restore.txt"] or ""):find("charges = 1 40.00", 1, true) ~= nil,
        "the journal still has what was there before the first match")
    s:run(3.5)
    check(hm.phase == "fight" and gm.phase == "fight", "the second match's fight is on: " .. hm.phase .. "/" .. gm.phase)
    Session.command(g, "arena down")
    s:run(1)
    check(hm.score[1] == 1 and gm.score[1] == 1, "1 - 0 on both")
    s:run(7.5)
    check(hm.round == 2 and hm.phase == "fight" and gm.phase == "fight", "round 2: " .. hm.round .. " " .. hm.phase)
    Session.command(g, "arena down")
    s:run(1)
    check(hm.score[1] == 2 and gm.score[1] == 2, "2 - 0 to the host")
    s:run(3)
    check(hm.phase == "finish" and gm.phase == "finish", "the finishing window again: " .. hm.phase .. "/" .. gm.phase)
    -- (No blow this time: the window runs out, the last screens, and this time nobody calls it: home.)
    for _ = 1, 240 do
        if hm.phase ~= "finish" then
            break
        end
        s:run(0.05)
    end
    check(hm.phase == "result" or ha.match == nil, "the results: " .. tostring(ha.match and ha.match.phase))
    s:run(8)
    check(ha.match == nil and ga.match == nil, "both went home")
    check(count(h.logs, "again, match 2") == 1 and count(g.logs, "again, match 2") == 1, "one rematch on both, logged")
    s:run(5)
    check(not h.env.PBZ.net.arena and not g.env.PBZ.net.arena, "the network is whole again")
    check(not h.env.PBZ.net.pvp and not g.env.PBZ.net.pvp, "nobody fights after it")
    check(g.difficulty == 1 and g.files["difficulty_own.txt"] == nil, "home: the guest's own Wayfarer again: " .. g.difficulty)
    check(h.difficulty == 4 and daysWindow(h) == 6, "and the host's 66 Days with its own 6-frame window again: "
        .. h.difficulty .. ", " .. daysWindow(h))
    Session.command(g, "difficulty hellwalker")     -- (as the ini has it, for the rest)
    -- (The game's DeactivateAllNodes took a player's own nodes too, and nothing put them back: the next save kept that.)
    check(onNodes(h) == OWN and h.slots.HeiShi == true, "home: the host's own three nodes on, its talisman slot open: " .. onNodes(h))
    check(table.concat(hList, ",") == "AC_Deflect,None,None,None" and talismanCalls[#talismanCalls] == "on AC_Deflect 0 (1 open)",
        "the host's talisman back in its own slot, once the match's slots were shut: " .. table.concat(hList, ","))
    check(onNodes(g) == "", "the guest's tree as it was, nothing on: " .. onNodes(g))
    check(math.abs(attack(h) - attack0) < 0.5, string.format("and its attack its own again, %.0f, not the match's: %.0f",
        attack0, attack(h)))
    check(math.abs((Fake.health(h.pawn)) - 600) < 0.5, "and the health it had before, not a free heal: " .. tostring((Fake.health(h.pawn))))
    check(count(h.trace, "PBZHUDLayout ForSeq_UpdatePlayerHP 0%.6") >= 1, "and its own bar told so, 600 of 1000, not the match's last")
    check(gourd(h) == gourd0 and gourd(g) == gourd0, "the gourd as it was, its drinks, size and level: " .. gourd(h) .. ", " .. gourd(g))
    local hb2 = rawget(h.bag, "__fields")
    check(hb2.MedicineExtraUsage == 1 and rawget(g.bag, "__fields").MedicineExtraUsage == 1,
        "the extra drink each owns back, no more: " .. hb2.MedicineExtraUsage)
    check(hb2.ult.n == 1 and math.abs(hb2.ult.pct - 40) < 0.01, string.format(
        "the Combat Art's charges as they were, 1 and 40%% of the next: %d and %.0f%%", hb2.ult.n, hb2.ult.pct))
    check(countFrom(h.sent, sentGap, "^E K sp:dead1") >= 1, "the dead told again once the match is over")
    check(count(h.logs, "TIME'S UP") == 0, "no TIME'S UP in a match the clock didn't end")
    check(count(h.treeCalls, "AllNodes") == 0 and count(g.treeCalls, "AllNodes") == 0
        and count(h.treeCalls, "^DeactivateNode HeiShi1$") == 0, "the whole tree never switched, nor a node of the player's own")

    out("Death, a 60 s clock, decided by the clock:")
    Session.command(g, "difficulty pathbreaker")    -- (the guest's CoopDifficulty Pathbreaker, its own pick Wayfarer)
    g.difficulty = 1
    Session.command(h, "arena mode death")
    Session.command(h, "arena timer 60")
    Session.command(g, "arena ready")
    s:run(1.5)
    check(g.difficulty == 2, "with a partner the guest's Wayfarer is its CoopDifficulty, Pathbreaker: " .. g.difficulty)
    Session.command(h, "arena start")
    s:run(7)
    local dm, dg = ha.match, ga.match
    check(dm and dg and dm.mode == "death" and dm.timer == 60 and dm.phase == "fight" and dg.phase == "fight",
        "a Death match with a 60 s clock is on: " .. tostring(dm and dm.mode) .. " " .. tostring(dm and dm.timer))
    check(g.difficulty == 3, "in it, Hellwalker: " .. g.difficulty)
    local fins = count(h.sent, "^E AR fin")
    Fake.setHealth(g.pawn, 700)         -- (the guest behind on health as the clock runs out)
    s:run(30)
    check(dm.phase == "fight", "half way, still on: " .. tostring(dm.phase))
    s:run(33)
    check(dm.score[1] == 1 and dm.winner == 1 and dm.phase == "finish",
        string.format("at zero the clock gives it to the host, ahead on health: %d - %d, %s", dm.score[1], dm.score[2], dm.phase))
    check(dg.phase == "finish" and dg.winner == 1, "the guest's world has the same end: " .. tostring(dg.phase))
    check(last(h.sent, "^E AR round"):find(" 1$") ~= nil, "the host says the clock ended it: " .. last(h.sent, "^E AR round"))
    check(count(h.logs, "TIME'S UP") >= 1 and count(g.logs, "TIME'S UP") >= 1, "TIME'S UP on both screens")
    Session.command(h, "arena finish 2 1")
    s:run(1)
    check(count(h.sent, "^E AR fin") == fins + 1 and dg.finished == 2, "the host finishes the guest, one life, no more rounds")
    s:run(16)
    check(ha.match == nil and ga.match == nil, "both home after the results")
    s:run(5)
    check(g.difficulty == 2 and g.files["difficulty_own.txt"] == "1 2",
        "home, the partner still there: back down to Pathbreaker, its own Wayfarer kept for when it's alone: "
        .. g.difficulty .. ", " .. tostring(g.files["difficulty_own.txt"]))
    Session.command(g, "difficulty hellwalker")

    out("a guest leaving ends it:")
    Session.command(g, "arena ready")
    s:run(1.5)
    Session.command(h, "arena start")
    s:run(7)
    check(ha.match and ga.match and ha.match.phase == "fight", "a second match is on")
    Session.command(g, "arena leave")
    s:run(2)
    check(ha.match == nil and ga.match == nil, "the guest left: both home")
    s:run(5)

    local function errorsIn(sess, label)
        local n = 0
        for _, pc in ipairs(sess.pcs) do
            for _, e in ipairs(pc.errors) do
                n = n + 1
                if n <= 6 then out("  error " .. label .. " " .. tostring(pc.name or pc.id) .. ": " .. e) end
            end
        end
        return n
    end
    local errors = errorsIn(s, "duel")
    for _, pc in ipairs(s.pcs) do
        for _, l in ipairs(pc.logs) do
            if l:find("arena:") or l:find("PvP") then
                out("    " .. tostring(pc.name or pc.id) .. " " .. l:sub(1, 220))
            end
        end
    end

    out("three players, teams: the host alone against two guests:")
    local t = Session.new(scripts, { "Host", "Guest", "Guest" }, 3,
        { { "near", "BP_Monster_MaleThug_Sword_Blue_C", 300.0, 0.0, 100.0, 850, 400, false } }, nil)
    local p1, p2, p3 = t.pcs[1], t.pcs[2], t.pcs[3]
    t:run(5)
    Session.moveTo(p1, 0, 0)
    Session.moveTo(p2, 400, 0)
    Session.moveTo(p3, 0, 400)
    t:run(3)
    local a1, a2, a3 = p1.env.PBZ.arena, p2.env.PBZ.arena, p3.env.PBZ.arena
    Session.command(p1, "arena place 0")
    Session.command(p1, "arena team 1")
    Session.command(p2, "arena team 2")
    Session.command(p3, "arena team 2")
    Session.command(p2, "arena ready")
    Session.command(p3, "arena ready")
    t:run(2)
    check(a1.blocker() == nil, "three ready, two teams: nothing stops the start: " .. tostring(a1.blocker()))
    Session.command(p1, "arena start")
    t:run(9)
    local m1, m2, m3 = a1.match, a2.match, a3.match
    check(m1 and m2 and m3 and m1.phase == "fight" and m2.phase == "fight" and m3.phase == "fight",
        "all three fight: " .. tostring(m1 and m1.phase) .. "/" .. tostring(m2 and m2.phase) .. "/" .. tostring(m3 and m3.phase))
    check(m1 and m1.teams[1] == 1 and m1.teams[2] == 2 and m1.teams[3] == 2, "the teams as picked")
    -- A teammate's bar over the player's own (its frame's middle at 316, 902 on a screen 1080 high): on each guest's screen
    -- the other guest's, on the lone host's none.
    local function mateBar(pc)
        for _, w in ipairs(pc.widgets or {}) do
            local f = rawget(w, "__fields") or {}
            local at = f.position
            if at and math.abs(at.X - 316) < 1 and math.abs(at.Y - 902) < 1 and not f.removed then
                return true
            end
        end
        return false
    end
    check(mateBar(p2) and mateBar(p3) and not mateBar(p1), "a teammate's bar on each guest's screen, none on the lone host's")
    Session.command(p2, "arena down")
    t:run(3)
    check(m1 and m1.phase == "fight" and m1.down[2], "one Azure down, the other fights on: " .. tostring(m1 and m1.phase))
    check(m2 and m2.phase == "out", "the fallen guest is out of the round: " .. tostring(m2 and m2.phase))
    check(m2 and m2.watching == true and p2.env.PBZ.net.arenaWatching == true,
        "the fallen guest's camera is on its teammate: " .. tostring(m2 and m2.watching))
    Session.command(p3, "arena down")
    t:run(1.5)
    check(m1 and m1.score[1] == 1 and m1.score[2] == 0, "both Azure down: the round to Crimson, 1 - 0: " ..
        tostring(m1 and m1.score[1]) .. " - " .. tostring(m1 and m1.score[2]))
    t:run(6)
    check(m2 and m2.round == 2 and not m2.watching and not p2.env.PBZ.net.arenaWatching,
        "round 2: everyone up, the camera back: round " .. tostring(m2 and m2.round))
    Session.command(p1, "arena leave")
    t:run(3)
    check(a1.match == nil and a2.match == nil and a3.match == nil, "the host left: all three home")
    errors = errors + errorsIn(t, "teams")

    out("five players: three a side at most (each arena has three spots a side):")
    local f = Session.new(scripts, { "Host", "Guest", "Guest", "Guest", "Guest" }, 6,
        { { "near", "BP_Monster_MaleThug_Sword_Blue_C", 300.0, 0.0, 100.0, 850, 400, false } }, nil)
    f:run(8)
    for i, pc in ipairs(f.pcs) do
        Session.moveTo(pc, 300 * i, 0)
    end
    f:run(3)
    local fa = f.pcs[1].env.PBZ.arena
    Session.command(f.pcs[1], "arena place 0")
    Session.command(f.pcs[1], "arena team 1")
    for i = 2, 5 do
        Session.command(f.pcs[i], "arena team 2")
        Session.command(f.pcs[i], "arena ready")
    end
    f:run(2)
    check(tostring(fa.blocker()):find("Three a side", 1, true) ~= nil, "four on one side: refused: " .. tostring(fa.blocker()))
    Session.command(f.pcs[5], "arena team 1")
    Session.command(f.pcs[5], "arena ready")
    f:run(2)
    check(fa.blocker() == nil, "two against three: nothing stops the start: " .. tostring(fa.blocker()))
    errors = errors + errorsIn(f, "five")

    -- (The review of 3f77be8: difficulty.lua ran as one of coop's extraTicks, which stop with sync, so co-op turned off in a
    -- match left the hold and 66 Days' window as they were; and back at the player's own after a match it set the same mode
    -- again every second.)
    out("the game's difficulty: co-op turned off in a match, and back at the player's own after one:")
    do
        local function duel(ini)
            local d = Session.new(scripts, { "Host", "Guest" }, false,
                { { "near", "BP_Monster_MaleThug_Sword_Blue_C", 300.0, 0.0, 100.0, 850, 400, false } }, ini)
            local dh, dg = d.pcs[1], d.pcs[2]
            d:run(4)
            Session.moveTo(dh, 0, 0)
            Session.moveTo(dg, 500, 0)
            d:run(2)
            return d, dh, dg
        end
        local function start(d, dh, dg)
            Session.command(dh, "arena place 0")
            Session.command(dg, "arena ready")
            d:run(1.5)
            Session.command(dh, "arena start")
            d:run(8)
        end
        local d, dh, dg = duel("CoopDifficulty = Off\n")
        dh.difficulty, dg.difficulty = 4, 1         -- (the host on 66 Days, the guest on Wayfarer)
        d:run(1.5)
        start(d, dh, dg)
        check(dh.difficulty == 4 and daysWindow(dh) == 8 and dg.difficulty == 3,
            "in the match: 66 Days at 8 frames, the Wayfarer at Hellwalker: " .. dh.difficulty .. " " .. daysWindow(dh) .. ", "
            .. dg.difficulty)
        Session.command(dh, "netoff")
        Session.command(dg, "netoff")
        d:run(5)
        check(dh.env.PBZ.net.enabled == false and dg.env.PBZ.net.enabled == false, "co-op turned off on both in the match")
        check(dh.difficulty == 4 and daysWindow(dh) == 6, "66 Days' own 6 frames back with co-op off: " .. daysWindow(dh))
        check(dg.difficulty == 1 and dg.files["difficulty_own.txt"] == nil,
            "the guest's own Wayfarer back with co-op off, no file left: " .. dg.difficulty)
        errors = errors + errorsIn(d, "netoff")

        local e, eh, eg = duel("CoopDifficulty = Wayfarer\n")      -- (both on the save's Pathbreaker)
        start(e, eh, eg)
        check(eg.difficulty == 3, "CoopDifficulty Wayfarer, own Pathbreaker: Hellwalker in the match: " .. eg.difficulty)
        Session.command(eh, "arena leave")
        Session.command(eh, "arena leave")
        e:run(10)
        local logs0, sets0 = count(eg.logs, "the match is over: "), count(eg.trace, "SetDifficultMode")
        e:run(30)
        check(eg.difficulty == 2 and eg.files["difficulty_own.txt"] == nil,
            "home, the partner still there: its own Pathbreaker, nothing held: " .. eg.difficulty)
        check(count(eg.logs, "the match is over: ") == logs0 and count(eg.trace, "SetDifficultMode") == sets0,
            "and nothing set again for 30 s: " .. (count(eg.trace, "SetDifficultMode") - sets0) .. " more")
        errors = errors + errorsIn(e, "stepdown")
    end
    check(errors == 0, "no script errors: " .. errors)
    out(failed == 0 and "PASS" or ("FAILED " .. failed))
    return failed == 0
end
