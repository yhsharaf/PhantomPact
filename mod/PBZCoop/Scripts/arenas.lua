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

-- unlock: spawner save keys (map name and spawner object, as the game's SpawnerSaveData has them): any one dead opens it.
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
        unlock = { "PBZ_Fujizhilin_WPBP_AISpawner_C_UAID_E89C25A75433A3D602_1516000262",
            "PBZ_Fujizhilin_WPBP_AISpawner_C_UAID_E89C25A75433A5D602_1440794636",
            "PBZ_Fujizhilin_WPBP_AISpawner_C_UAID_E89C25A75433A5D602_1442751637" },
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

-- Everyone fights as a Soul at the top of the game: every skill node on (the game's own ActivateAllNodes, max level),
-- which the bench read as these (850 / 100 / 400 / 100 without them).
data.STATS = { Health_Max = 1360, Attack = 160, Shachi_Max = 640, ShachiAttack = 160 }
data.WEAPON_LEVEL = 30

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
