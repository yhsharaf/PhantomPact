-- What PvP (F6) is played with: the four arenas, the weapons a loadout can hold, and the gourd everyone drinks from.
-- Arena places were surveyed on the bench: each one's floor (flat within a metre where the teams start), its fog walls,
-- the boss spawners whose deaths open it (docs/PVP.md). A boss's arena is only offered once every player's own save has
-- that boss beaten: going there before plays its story (seen on the bench: Mu Xiaokui's scene, the forest's).

-- Three spots a side, the sides `r` cm from the middle along `yaw` (team 1 on the far side of it, facing back).
local function spots(c, r, yaw)
    local out = { {}, {} }
    local a = math.rad(yaw)
    local ax, ay = math.cos(a), math.sin(a)
    local sx, sy = -ay, ax              -- across the line, for the second and third
    for team = 1, 2 do
        local side = team == 1 and -1 or 1
        local face = (yaw + (team == 1 and 0 or 180)) % 360
        for n, across in ipairs({ 0, 300, -300 }) do
            out[team][n] = {
                X = c.X + ax * r * side + sx * across,
                Y = c.Y + ay * r * side + sy * across,
                Z = c.Z,
                Yaw = face,
            }
        end
    end
    return out
end

local data = { spots = spots }
data.PER_SIDE = 3               -- players a side at most: the spots above

-- unlock: spawner save keys (map name and spawner object, as the game's SpawnerSaveData has them): any one dead opens it,
-- unless that world showed the fight unfinished this session (arena.storyBegan). A boss of phases lists its last phase's: Mu
-- Xiaokui's MuXiaoKuiP2_Seq046new, YuCong's three bodies YuCong_P3_1/2/3 (by SpawnerID, the bench's spawner survey of 11-06).
-- His first phase (the kneeling BP_Monster_YuCong_P1_C and a BP_Monster_YuCong_C: SanTouMoOu, YuCong_Seqs028) isn't listed.
data.arenas = {
    {
        key = "yucong",
        name = "Crimson Forest",
        zh = "赤林",
        boss = "YuCong",
        map = "PBZ_Fujizhilin_WP",
        center = { X = 17300, Y = 153100, Z = -1932 },
        line = 0,               -- the teams face each other along this yaw
        reach = 2600,           -- the fight stays within this of the middle
        unlock = { "PBZ_Fujizhilin_WPBP_AISpawner_C_UAID_E89C25A75433A3D602_1516000262",   -- YuCong_P3_1
            "PBZ_Fujizhilin_WPBP_AISpawner_C_UAID_E89C25A75433A5D602_1440794636",          -- YuCong_P3_2
            "PBZ_Fujizhilin_WPBP_AISpawner_C_UAID_E89C25A75433A5D602_1442751637" },        -- YuCong_P3_3
    },
    {
        key = "huaqianxiao",
        name = "Hua Qianxiao's Stage",
        zh = "花千笑",
        boss = "Hua Qianxiao",
        map = "PBZ_Fujizhilin_WP",
        center = { X = -132300, Y = 170800, Z = -1390 },
        line = 0,
        reach = 2300,
        unlock = { "PBZ_Fujizhilin_WPBP_AISpawner_C_UAID_E89C25A75434C64402_2081298396" },
    },
    {
        key = "goldmask",
        name = "The Gold-Masked One's Gorge",
        zh = "金面人",
        boss = "the Gold-Masked One",
        map = "PBZ_Xigu_WP",
        center = { X = -20900, Y = 291300, Z = -26450 },
        line = 90,
        reach = 2200,
        unlock = { "PBZ_Xigu_WPBP_AISpawner_C_UAID_60CF848099094D6202_1282307163" },
    },
    {
        key = "muxiaokui",
        name = "Mu Xiaokui's Meadow",
        zh = "木小葵",
        boss = "Mu Xiaokui",
        map = "PBZ_Zhengdaodaying_WP",
        center = { X = -68100, Y = 77200, Z = 860 },
        line = 90,
        reach = 2600,
        unlock = { "PBZ_Zhengdaodaying_WPBP_AISpawner_C_UAID_E89C25A75434197502_1369350133" },
    },
}
for _, a in ipairs(data.arenas) do
    a.spots = spots(a.center, 800, a.line)
end

-- "Here": wherever the host stands, on a map everyone is on. Its middle and line are the host's own at the start.
data.HERE = { key = "here", name = "Here", zh = "此地", reach = 2500 }

-- The healing gourd everyone gets in a match: the game's own, the same for all, this many drinks for the whole match.
data.GOURD = "Hulu"
data.DRINKS = 3
-- ...at its top level for everyone: a drink heals by the gourd's level (the bench, 11-08: 40% of the health at level 0, 45%
-- at 3, 50% at 6), and the gourd is made to hold just the match's drinks.
data.GOURD_LEVEL = 6

-- Everyone fights as a Soul at the top of the game: every skill node on (the game's own ActivateAllNodes, max level),
-- which the bench read as these (850 / 100 / 400 / 100 without them).
data.STATS = { Health_Max = 1360, Attack = 160, Shachi_Max = 640, ShachiAttack = 160 }
data.WEAPON_LEVEL = 30
-- Every blow in a match at this share of the game's own (each world's, the same for all): at the top of the game a
-- Sanguine blow took 499 of 1360, three to fall (the bench, 11-06); at half, six or so, room for parries and reads.
data.DAMAGE = 0.5

-- Weapons a loadout can hold: the backpack's own ids (PBZBackPackSubsystem), with the game's English names (its own
-- localization, read on the bench) and Chinese ones (its weapon table's rows). kind: blade, twin, great.
data.weapons = {
    { id = "Tang", name = "SANGUINE", zh = "黑伤", kind = "blade" },
    { id = "IronBlade", name = "JAGGED STEEL", zh = "残钢刃", kind = "blade" },
    { id = "ChiZheCanJian", name = "THE FANATIC'S BROKEN BLADE", zh = "痴者残剑", kind = "blade" },
    { id = "SlitheringSword", name = "SOFT SNAKE SWORD", zh = "灵蛇软剑", kind = "blade" },
    { id = "ZiMingJian", name = "AUREATE", zh = "紫冥剑", kind = "blade" },
    { id = "LuanYing", name = "WILD ORIOLE SWORD", zh = "乱莺", kind = "blade" },
    { id = "HeiMoShang", name = "INFERNAL ROUGE", zh = "黑魔伤", kind = "blade" },
    { id = "Double", name = "SANGUINE TWIN", zh = "黑伤双刃", kind = "twin" },
    { id = "SnakeDual", name = "WHITE SERPENT & CRIMSON VIPER", zh = "白蟒赤练", kind = "twin" },
    { id = "DualHook", name = "PARTING HOOKS", zh = "别离残钩", kind = "twin" },
    { id = "JadeDualChakram", name = "SEAMLESS DEATH", zh = "玉双环", kind = "twin" },
    { id = "YuuBlade", name = "FIEND SAWS", zh = "妖锯", kind = "twin" },
    { id = "Long", name = "SANGUINE REACH", zh = "长形黑伤", kind = "great" },
    { id = "GuiTouBlade", name = "SCARLET WRAITHBLADE", zh = "红妆鬼斩", kind = "great" },
    { id = "ZhanMaBlade", name = "OUTLAW WARBLADE", zh = "亡命斩马刀", kind = "great" },
    { id = "PoJun", name = "ARMYBREAKER", zh = "破军", kind = "great" },
    { id = "HorizontalBlade", name = "JUGGERNAUT", zh = "荡寇凶刃", kind = "great" },
    { id = "Jigsaw", name = "BONESAW", zh = "断肢锯", kind = "great" },
    { id = "BaiYing", name = "WHITESHADOW", zh = "白影", kind = "great" },
    { id = "XieHuo", name = "BLAZING EDGE", zh = "邪火", kind = "great" },
}

-- Phantom Edge weapons (two in a loadout). kind: the game's own (ShaChiWeaponType).
data.edges = {
    { id = "ShachiHook", name = "HUNTER'S CHAIN SICKLE", zh = "追命锁镰", kind = "combat" },
    { id = "HuoLiuXing", name = "FIRE METEOR", zh = "火流星", kind = "combat" },
    { id = "MoJian", name = "INK CUT", zh = "墨血无痕", kind = "combat" },
    { id = "ThunderSpear", name = "THUNDER SPEAR", zh = "雷霆枪", kind = "combat" },
    { id = "BrutalAxe", name = "DREAD AXE", zh = "巨凶斧", kind = "damage" },
    { id = "JinGua", name = "BASHPOLE", zh = "长柄金瓜", kind = "damage" },
    { id = "TanLang", name = "WOLFJAW", zh = "贪狼", kind = "damage" },
    { id = "TigerCannon", name = "TIGER CANNON", zh = "虎炮", kind = "damage" },
    { id = "NiTouChe", name = "WAR WAGON", zh = "泥头车", kind = "damage" },
    { id = "UnnamedBow", name = "FEATHER BOW", zh = "羽弓", kind = "stunt" },
    { id = "MiaoShouFeiDao", name = "FLYING DAGGER", zh = "妙手飞刀", kind = "stunt" },
    { id = "HuangJinHuoChong", name = "GOLDBLAZE", zh = "黄金火铳", kind = "stunt" },
    { id = "YouLongCha", name = "LOONG TRIDENT", zh = "游龙叉", kind = "stunt" },
    { id = "ZhuoBiDun", name = "BASTION", zh = "拙壁盾", kind = "magic" },
    { id = "LionHead", name = "FLAMING MANE", zh = "烈焰狮头", kind = "magic" },
    { id = "XueDiZi", name = "FLYING GUILLOTINE", zh = "血滴子", kind = "magic" },
    { id = "KuYeSiZhuChuan", name = "KUYE TEMPLE PRAYER BEADS", zh = "苦叶寺珠串", kind = "summon" },
    { id = "CaoOuSiXian", name = "PUPPETEER'S BELL", zh = "操偶丝线", kind = "summon" },
    { id = "XuKongHuaShan", name = "INANIS' RADIANT FAN", zh = "虚空华扇", kind = "summon" },
    { id = "JianKeZhaoJiLing", name = "SWORDSMAN'S SUMMON", zh = "剑客召集令", kind = "summon" },
}

-- A loadout to start from: the game's first weapons.
data.DEFAULT = { main = { "Tang", "PoJun" }, edge = { "ShachiHook", "TigerCannon" } }

-- The game's own sounds at a match's big moments (Wwise events: its music's stingers, its UI's near-death loop; the stingers
-- picked by name from the game's 33). Swap any here.
local STINGERS = "/Game/Wwise/Events/Mus/Mus_Stinger/"
data.SOUNDS = {
    decided = STINGERS .. "Mus_MountainRoad_Stinger2_hit3_Loud",                -- the blow that decides the match
    finisher = STINGERS .. "Mus_MountainRoad_Stinger_metalBig3",                -- the finishing move lands
    victory = STINGERS .. "Mus_DuanHun_Stinger_Logo",                           -- the winners' 生还 (the game's own title)
    defeat = STINGERS .. "Mus_MountainRoad_Stinger_XinZangZhouSuo_01",          -- the fallen's 殒命 (心脏骤缩)
    heartbeat = "/Game/Wwise/Events/UI/UI_Plot/SFX_UI_Plot_NearDeath_Loop",     -- the fallen waiting for it
    heartbeatStop = "/Game/Wwise/Events/Stop/UI/SFX_UI_Plot_NearDeath_Loop_Stop",
    count = "/Game/Wwise/Events/UI/UI_Plot/SFX_UI_Plot_Impact_Po",                     -- each number: its story's 破 impact
    fight = "/Game/Wwise/Events/UI/UI_Plot/SFX_UI_Plot_Impact_Zhan",                   -- 斗: its story's slash (斩) impact
}

-- The beaten's stance while the winners come to finish them: the game's own posture-broken stagger for the player's body
-- (the long blades' one: its hunched sway lasts most of its 3.6 s; the Sanguine's is over in one), seen on the bench 11-07.
data.DAZED = "/PBZCombatAsset/ActorData/Players/Hun/Montage/LongBlade/Deflect/AM_Hun_Long_StanceWeak.AM_Hun_Long_StanceWeak"

-- How the finished body dies: the game's own death for the player's body (the user, 11-07: "Why death is not same as the way
-- the game does it"), seen on the bench: a stagger and a fall, held on its last frame.
data.DEATH = "/PBZCombatAsset/ActorData/Players/Hun/Montage/Hit/AM_Hun_Dead_F.AM_Hun_Dead_F"

-- The finishing moves. Each arena's is its boss's own move, played by the winner on their own body (the game marks the
-- bosses' skeletons alike with the player's: played on the bench 11-07, whole, the body carried the way the boss goes);
-- "here" draws one of the four. hit: seconds in, when the blow lands (the slow beat, the death). lead: where the move has
-- carried the body by then, cm ahead and cm to the right (and the room it needs behind its start, if it steps back first),
-- so the winner starts that far back and the blow lands on the beaten (the body's path read frame by frame on the bench;
-- each played in a real match there, both screens, 11-07). The Infernal Rouge's execution is the one for when a boss's
-- move can't load or has no room to run; it stays first, the number older worlds also know.
-- (The club bosses' leap and slam was the first: the user, 11-07, "the one you go up then down is wrong", so no move here
-- leaves the ground: Mu Xiaokui's skill that does was left out. The archer Du Yan's point-blank shot went with it.)
data.FINISHERS = {
    { key = "rouge",                -- the Infernal Rouge's execution: a spinning grab, the cut, the winner over the body
        path = "/PBZCombatAsset/ActorData/Players/Hun/Montage/HeiMoShang/ExE/Hun_HeiMoShang_EXE_F_04_Montage."
            .. "Hun_HeiMoShang_EXE_F_04_Montage", len = 4.07, hit = 2.3 },     -- (the overhead cut: film, 11-07)
    { key = "yucong", boss = "yucong",          -- YuCong's blade form: a step back, then the lunge
        path = "/HuaShira/Characters/Boss/YuCong/Anim/YuCong_Bing/YuCong_Bing_Skill_04_Montage."
            .. "YuCong_Bing_Skill_04_Montage", len = 3.20, hit = 2.05, lead = { 10, 0, 110 } },  -- (105 cm back first)
    { key = "huaqianxiao", boss = "huaqianxiao", -- Hua Qianxiao's drunken slide and rising cut
        path = "/HuaShira/Characters/EliteMonster/HuaQianXiao/Anim/Montage/HuaQianXiao_Attack_04_Montage."
            .. "HuaQianXiao_Attack_04_Montage", len = 5.77, hit = 2.5, lead = { 351, -11 } },
    { key = "goldmask", boss = "goldmask",      -- the Gold-Masked One's lunge and upward cut
        path = "/PBZCombatAsset/ActorData/Mobs/006_GoldMaskMan/Montage/Attack/GoldMaskMan_AtkCombo_A01_Montage."
            .. "GoldMaskMan_AtkCombo_A01_Montage", len = 3.00, hit = 1.35, lead = { 335, 10 } },
    { key = "muxiaokui", boss = "muxiaokui",    -- Mu Xiaokui's twin blades: the turning dash
        path = "/HuaShira/Characters/EliteBoss/MuXiaoKui/Anim/Montage/MuXiaoKui_SpecialAttack_05_Montage."
            .. "MuXiaoKui_SpecialAttack_05_Montage", len = 2.67, hit = 1.3, lead = { 311, 203 } },
}

-- The finishing move for a match in this place (0: here): its boss's own; here, one of the bosses' drawn at random.
function data.finisherFor(place)
    local a = place and place > 0 and data.arenas[place]
    local list = {}
    for i, f in ipairs(data.FINISHERS) do
        if f.boss and (not a or f.boss == a.key) then
            list[#list + 1] = i
        end
    end
    return #list > 0 and list[math.random(#list)] or 1
end

local function byId(list, id)
    for i, w in ipairs(list) do
        if w.id == id then
            return w, i
        end
    end
    return nil
end

function data.weapon(id)
    return byId(data.weapons, id)
end

function data.edge(id)
    return byId(data.edges, id)
end

-- The arena by number (0: here).
function data.arena(n)
    if n == 0 then
        return data.HERE
    end
    return data.arenas[n]
end

return data
