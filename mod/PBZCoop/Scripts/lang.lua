-- The online mode's words on screen, in English or Chinese: picked on the online panel (F5), kept in PhantomPact.ini.
-- Everything is written in English and logged that way. say() turns a line into Chinese as it goes on screen, and a
-- line with no row here stays English. The panel's own pictures come in both (art/make_online_panel.py).

return function()
    local lang = { code = "en" }

    -- Whole lines.
    local LINES = {
        -- the panel
        ["Not connected."] = "未连接。",
        ["Starting..."] = "正在启动……",
        ["Waiting for a partner."] = "正在等待队友。",
        ["Looking for a Steam friend who's hosting..."] = "正在寻找开房的 Steam 好友……",
        ["Copy the host's address first, then press Paste."] = "请先复制房主的地址,再按“粘贴地址”。",
        ["Copy the password first, then press Paste password."] = "请先复制密码,再按“粘贴密码”。",
        ["Password set. Your partner needs the same one."] = "密码已设置。队友需要使用相同的密码。",
        ["Password removed."] = "密码已清除。",
        ["PhantomPact.ini: HostAddress isn't set. Put the host's Tailscale IP there, or use Steam."] =
            "还没有房主地址。请复制房主的地址后按“粘贴地址”,或者使用 Steam。",
        ["PhantomPact.ini: HostAddress has a character that can't be used (\" % & | < > ^). Leave it empty to join any friend who's hosting."] =
            "房主名称里有不能使用的字符(\" % & | < > ^)。留空即可加入任何正在开房的好友。",
        ["this game update isn't tested with this Phantom Pact version; some co-op features may fail."] =
            "这个游戏版本尚未用当前的 Phantom Pact 测试过,部分联机功能可能失效。",
        ["Couldn't start the relay: dlls\\main.dll can't be reached. Reinstall Phantom Pact, check your antivirus didn't remove it, and use the UE4SS build from the install guide."] =
            "无法启动联机模块:找不到 dlls\\main.dll。请重新安装 Phantom Pact,检查杀毒软件是否删除了它,并使用安装说明里的 UE4SS 版本。",
        -- PvP (F6)
        ["Putting the last match back: a moment."] = "正在还原上一场对决,请稍候。",
        ["too late to finish them: the match is over."] = "来不及处决了:对决已经结束。",
        -- the partner
        ["your partner is down."] = "队友倒下了。",
        ["your partner is back."] = "队友回来了。",
        ["your partner is watching a cutscene."] = "队友正在观看过场动画。",
        ["your partner rested at a bell: you'll join them."] = "队友在钟旁休息了:你会前往队友身边。",
        ["your partner rested at a bell: you're rested too."] = "队友在钟旁休息了:你也恢复了。",
        ["your partner rested at a bell: you're rested, and so is the boss."] = "队友在钟旁休息了:你恢复了,首领也恢复了。",
        ["your partner needs PvPvE on too, or their moves won't show here."] = "队友也要开启 PvPvE,否则这里看不到对方的动作。",
        ["partner disconnected."] = "队友已断开连接。",
        ["your partner turned co-op sync off."] = "队友关闭了联机同步。",
        ["PvPvE is off with more than two players (F6 PvP has teams)."] = "超过两名玩家时 PvPvE 关闭(F6 的 PvP 可以分队)。",
        ["Local co-op starts the next time you start the game."] = "下次启动游戏时开始本地分屏。",
        ["Only the host's Players setting counts."] = "只有房主的人数设置有效。",
        ["Only the host's setting counts."] = "只有房主的设置有效。",
        ["Players: from your next Host (Leave, then Host)."] = "人数:下次开房时生效(先离开,再开房)。",
        ["Multiplayer starts the next time you start the game."] = "下次启动游戏时恢复多人联机。",
        ["TP > PARTNER is off. Turn it on in MORE (F5)."] = "传送到队友已关闭。可在 F5 的“更多”里开启。",
        ["couldn't reach your partner in time. TP > PARTNER in MORE (F5) can take you there."] =
            "没能及时传送到队友身边。可在 F5 的“更多”里开启传送到队友。",
        ["no partner to go to yet."] = "还没有可以传送的队友。",
        ["not now."] = "现在不能传送。",
        ["finish the prologue first."] = "请先完成序章。",
        ["you're in the prologue: finish it first, or start a New Game and choose the game's own skip there."] =
            "你在序章中:请先完成序章,或者开始新游戏时选择游戏自带的跳过序章。",
        ["to skip the prologue, start a New Game and choose the game's own skip there."] =
            "要跳过序章,请开始新游戏并选择游戏自带的跳过序章选项。",
        ["you're past the prologue."] = "你已经过了序章。",
        ["your partner is still in the prologue."] = "你的同伴还在序章中。",
        ["your partner can't be joined right now."] = "现在无法传送到队友身边。",
        ["your partner's position looks wrong."] = "队友的位置不正常。",
        ["your partner's map isn't known yet."] = "还不知道队友在哪张地图。",
        ["the game wouldn't go there."] = "游戏无法前往那里。",
        -- revive
        ["you're down: you'll be back when the fight is over."] = "你倒下了:战斗结束后才会复活。",
        ["your partner is in a boss fight: you'll join them when it's over."] = "队友正在首领战中:战斗结束后你会前往队友身边。",
        ["your partner is in a boss fight: you'll join them when it's over. F3 takes you in now."] =
            "队友正在首领战中:战斗结束后你会前往队友身边。按 F3 可立即加入。",
        ["your partner is in a boss fight: press E at the black wall to join."] = "队友正在首领战中:在黑色雾墙前按 E 即可加入。",
        ["your partner is in a boss fight: press E at the black wall, or F3, to join."] = "队友正在首领战中:在黑色雾墙前按 E 或按 F3 即可加入。",
        ["the fight is taking long: you're free to move. F3 takes you to your partner."] = "战斗持续太久:你现在可以自由行动了。按 F3 前往队友身边。",
        ["your partner is in a boss fight: F3 takes you there, if you want to join."] = "队友正在首领战中:想加入的话按 F3 传送过去。",
        ["no ground past the wall here: try another part of it."] = "这里的雾墙后面没有落脚处:换一段墙试试。",
        ["your PC's clock and your partner's are over 2 minutes apart: set both to the right time."] = "你的电脑时间和队友的相差超过 2 分钟:请把两台电脑的时间都调准。",
        ["You're back on your feet."] = "你重新站起来了。",
        ["You're down: your partner can strike you to bring you back."] = "你倒下了:队友攻击你就能把你救起。",
        ["Your partner is down: strike them to bring them back."] = "队友倒下了:攻击队友就能把对方救起。",
        ["Your partner is back on their feet."] = "队友重新站起来了。",
        -- PvP (F6)
        ["Play online first (F5): PvP is between linked players."] = "请先联机(F5):PvP 在联机的玩家之间进行。",
        ["Play online first (F5): PvP is between linked players. Your loadout is kept for when you are."] =
            "请先联机(F5):PvP 在联机的玩家之间进行。你的配装会一直保留。",
        ["The host starts the match."] = "由房主开始对决。",
        ["Nobody to fight: a partner needs to be linked."] = "没有对手:需要有队友联机。",
        ["Both teams need someone."] = "两支队伍都需要有人。",
        ["Three a side at most: someone needs to change team."] = "每队最多三人:需要有人换队。",
        ["Everyone's ready: START when you are."] = "所有人都已准备:随时可以开始。",
        ["You're ready. The host starts the match."] = "你已准备。等待房主开始对决。",
        ["Set your loadout, pick a team, then READY."] = "设定配装、选择队伍,然后按“准备”。",
        ["Click one to take it; BACK keeps what you had."] = "点击即可选用;按“返回”保留原来的。",
        ["In a match: LEAVE twice ends it for everyone."] = "对决中:按两次“离开”会结束所有人的对决。",
        ["can't get to the arena from here."] = "从这里无法前往战场。",
        ["press LEAVE again to end the match for everyone."] = "再按一次“离开”结束所有人的对决。",
        ["get closer to a fallen foe to finish them."] = "靠近倒下的对手才能处决。",
        ["a match was cut short by the game closing: back to where it began."] = "游戏关闭使对决中断:已回到对决开始的地方。",
        ["the host sets the match."] = "对决由房主设定。",
        ["two players: one team each."] = "两名玩家:各自一队。",
        ["the loadout changes for the next match."] = "配装将在下一场对决生效。",
        -- the connection
        ["nobody has joined yet. Your partner needs Role = Guest and your address: two Hosts never find each other."] =
            "还没有人加入。队友要按“加入”并使用你的地址:两边都开房是找不到对方的。",
        ["packets refused: both PCs need the same Secret in PhantomPact.ini (or both none), and their clocks within two minutes of each other."] =
            "连接被拒绝:双方的密码必须相同(或都不设),两台电脑的时间相差也不能超过两分钟。",
        ["Steam is relaying this connection, which adds delay. A direct one needs SteamDirect = On on both PCs and routers that allow it."] =
            "这次连接经过 Steam 中继,延迟会更高。要直连,双方都要开启 Steam 直连,路由器也要允许。",
    }

    -- Parts of lines, in this order. What's around them stays as it is.
    local PARTS = {
        { "^Connected to (%S+)%.", "已连接到 %1。" },
        { " Ping (%d+) ms%.", " 延迟 %1 毫秒。" },
        { " Route: direct%.", " 线路:直连。" },
        { " Route: relay%.", " 线路:中继。" },
        { "^Couldn't start: ", "无法启动:" },
        { "^Couldn't start the relay: net_start%.txt can't be written in (.+)$", "无法启动联机模块:无法写入 %1 里的 net_start.txt" },
        { "^Looking for (.+)%.%.%.$", "正在寻找 %1……" },
        { "^Host address set to (.+)%.$", "房主地址已设置为 %1。" },
        { "^your partner is on another map%.", "队友在另一张地图上。" },
        { "^your partner is (%d+) m away%.", "队友在 %1 米外。" },
        { " F3 takes you there%.$", " 按 F3 传送过去。" },
        { "^partner connected %(ping (%d+) ms%)", "队友已连接(延迟 %1 毫秒)" },
        { "^partner connected", "队友已连接" },
        { ", signed%.$", ",已签名。" },
        { "^your bag now has what your partner's has %((%d+) new%)%.$", "你的背包已补齐队友有的东西(新增 %1 件)。" },
        { "^(队友已连接.-)%.$", "%1。" },
        { "^co%-op couldn't start: ", "无法开始联机:" },
        { "^Steam couldn't connect: (.+)%. See Connection problems in the install guide%.$",
            "Steam 无法连接:%1。请查看安装说明里的“连接问题”。" },
        { "^settings differ from your partner's: ", "你和队友的设置不同:" },
        { "^your partner's Phantom Pact %((.+)%) can't connect to (.+): both PCs need the same version%.$",
            "队友的 Phantom Pact(%1)无法连接到 %2:双方必须使用相同的版本。" },
        { "^your partner is on Phantom Pact (.+) and you're on (.+): use the same version, or enemies won't stay in step%.$",
            "队友使用 Phantom Pact %1,你使用 %2:请使用相同的版本,否则敌人会不同步。" },
        { "^high ping %((%d+) ms%)%.", "延迟过高(%1 毫秒)。" },
        { " On Tailscale, run \"tailscale ping\": via DERP means relayed%.$",
            " 使用 Tailscale 时可运行 “tailscale ping”:显示 via DERP 表示经过了中继。" },
        { "^no answer from the host %((.+)%)%. Check HostAddress and Port, that they're in the game on Role = Host, and the same Secret and Phantom Pact version on both PCs%.$",
            "房主(%1)没有回应。请检查地址和端口、房主是否已在游戏里开房,以及双方的密码和 Phantom Pact 版本是否相同。" },
        { "^no friend hosting found%..*$",
            "没有找到正在开房的好友。你们必须是 Steam 好友,对方要开房并使用 Steam,而且不能隐身;双方的密码和 Phantom Pact 版本也要相同。" },
        { "^无法启动:couldn't find the host address (.+)$", "无法启动:找不到房主地址 %1" },
        { "^无法启动:UDP port (%d+) is in use on this PC %(error (%d+)%): set another Port in PhantomPact%.ini on both PCs$",
            "无法启动:这台电脑的 UDP 端口 %1 已被占用(错误 %2)。请在双方的 PhantomPact.ini 里改用别的端口。" },
        { "^无法启动:UDP port (%d+) can't be used %(error (%d+)%): set another Port in PhantomPact%.ini on both PCs$",
            "无法启动:UDP 端口 %1 无法使用(错误 %2)。请在双方的 PhantomPact.ini 里改用别的端口。" },
        { "^无法启动:Steam isn't loaded in this game %(steam_api64%.dll%)$", "无法启动:游戏里没有加载 Steam(steam_api64.dll)。" },
        { "^无法启动:Steam isn't ready: is it running and logged in%?$", "无法启动:Steam 还没准备好,请确认它已运行并已登录。" },
        { "^your story caught up with the host's: (%d+) steps?%.$", "你的剧情进度已追上房主:%1 步。" },
        -- More than two players. (Each player's own lines are added below.)
        { " Players: (%d) of (%d)%.", " 玩家:%1/%2。" },
        { "^someone tried to join, but the party is full %((%d) players%)%.$", "有人想加入,但队伍已满(%1 名玩家)。" },
        { "^player (%d) is on Phantom Pact (.+) and you're on (.+): use the same version, or enemies won't stay in step%.$",
            "玩家 %1 使用 Phantom Pact %2,你使用 %3:请使用相同的版本,否则敌人会不同步。" },
        -- PvP (F6). Players' names first, as the lines below them say.
        { "^Waiting for (.+) to be ready%.$", "等待 %1 准备。" },
        { "^(.+) needs Phantom Pact (.+) for PvP%.$", "%1 需要 Phantom Pact %2 才能进行 PvP。" },
        { "^(.+) is on Phantom Pact (.+): everyone needs (.+)%.$", "%1 使用 Phantom Pact %2:所有人都需要 %3。" },
        { "^(.+) hasn't beaten (.+) yet: that arena opens after the fight%.$", "%1 还没有击败%2:击败后才能使用这个战场。" },
        { "^(.+) is on another map: for Here, everyone on (.+) %(F3 takes you to a partner%)%.$",
            "%1 在另一张地图上:“此地”需要所有人都在 %2(按 F3 可前往队友身边)。" },
        { "^everyone needs (.+) beaten in their own game for that arena%.$", "这个战场需要所有人都在自己的游戏里击败%1。" },
        { "^Waiting to hear the host's match %(the host needs Phantom Pact (.+)%)%.$", "正在等待房主的对决信息(房主需要 Phantom Pact %1)。" },
        { "^Duel, best of three, ", "决斗,三局两胜," },
        { "^Death, one life, ", "死斗,一条命," },
        { "no clock%. ", "不限时。" },
        { "(%d+) s a round%. ", "每回合 %1 秒。" },
        { "Crimson team%. ", "赤队。" },
        { "Azure team%. ", "青队。" },
        { "To (.+)%.$", "前往%1。" },
        { "^back from the match: the match is over%.$", "对决结束,已返回。" },
        { "^back from the match: you left%.$", "你离开了对决,已返回。" },
        { "^back from the match: you died%.$", "你在对决中死亡,已返回。" },
        { "^back from the match: a player was lost%.$", "有玩家断线,对决结束,已返回。" },
        { "^back from the match: the host was lost%.$", "房主断线了,对决结束,已返回。" },
        { "^back from the match: co%-op was turned off%.$", "联机已关闭,对决结束,已返回。" },
        { "^back from the match: the trip to the arena took too long%.$", "前往战场用时太久,对决取消,已返回。" },
        { "^back from the match: you couldn't get to the arena%.$", "你无法前往战场,对决取消,已返回。" },
        { "^back from the match: not everyone got to the arena in time%.$", "有人没能及时到达战场,对决取消,已返回。" },
        { "^back from the match: (.+) was lost%.$", "%1 断线了,对决结束,已返回。" },
        { "^back from the match: (.+) left%.$", "%1 离开了,对决结束,已返回。" },
        { "^back from the match: (.+) couldn't get to the arena%.$", "%1 无法前往战场,对决取消,已返回。" },
        { "^back from the match: (.+)%.$", "对决结束,已返回:%1。" },
    }

    -- What's said of a player by name, one row for each: they start with the name, so they can't reach any other line.
    for _, who in ipairs({ { "the host %(purple%)", "房主(紫)" }, { "player 2 %(green%)", "玩家 2(绿)" },
        { "player 3 %(gold%)", "玩家 3(金)" }, { "player 4 %(blue%)", "玩家 4(蓝)" },
        { "player 5 %(orange%)", "玩家 5(橙)" }, { "player 6 %(pink%)", "玩家 6(粉)" } }) do
        for _, line in ipairs({ { " joined%. (%d) players now%.$", " 加入了。现在有 %1 名玩家。" },
            { " left%. (%d) players now%.$", " 离开了。现在有 %1 名玩家。" }, { " is down%.$", " 倒下了。" }, { " is back%.$", " 回来了。" },
            { " is watching a cutscene%.$", " 正在观看过场动画。" }, { " is on another map%.$", " 在另一张地图上。" },
            { " is (%d+) m away%.$", " 在 %1 米外。" }, { " rested at a bell: you'll join them%.$", " 在钟旁休息了:你会前往对方身边。" },
            { " rested at a bell: you're rested too%.$", " 在钟旁休息了:你也恢复了。" },
            { " rested at a bell: you're rested, and so is the boss%.$", " 在钟旁休息了:你恢复了,首领也恢复了。" },
            { " turned co%-op sync off%.$", " 关闭了联机同步。" } }) do
            PARTS[#PARTS + 1] = { "^" .. who[1] .. line[1], who[2] .. line[2] }
        end
        PARTS[#PARTS + 1] = { " You're " .. who[1] .. "%.$", " 你是" .. who[2] .. "。" }
    end
    -- Last, names anywhere in a line, once the lines' own rows have had it: PvP's arenas (the longer names first, the
    -- F6 page's own words for them), its bosses, the players.
    for _, name in ipairs({ { "The Gold%-Masked One's Gorge", "金面人之谷" }, { "Hua Qianxiao's Stage", "花千笑之台" },
        { "Mu Xiaokui's Meadow", "木小葵之野" }, { "Crimson Forest", "赤林" }, { "前往Here。", "前往此地。" },
        { "the Gold%-Masked One", "金面人" }, { "Hua Qianxiao", "花千笑" }, { "Mu Xiaokui", "木小葵" }, { "YuCong", "余聪" },
        { "the host %(purple%)", "房主(紫)" }, { "player 2 %(green%)", "玩家 2(绿)" }, { "player 3 %(gold%)", "玩家 3(金)" },
        { "player 4 %(blue%)", "玩家 4(蓝)" }, { "player 5 %(orange%)", "玩家 5(橙)" }, { "player 6 %(pink%)", "玩家 6(粉)" } }) do
        PARTS[#PARTS + 1] = name
    end

    function lang.set(word)
        lang.code = (word or ""):lower() == "chinese" and "zh" or "en"
    end

    function lang.word()
        return lang.code == "zh" and "Chinese" or "English"
    end

    function lang.say(text)
        if lang.code ~= "zh" then
            return text
        end
        if LINES[text] then
            return LINES[text]
        end
        for _, row in ipairs(PARTS) do
            text = text:gsub(row[1], row[2])
        end
        return text
    end

    return lang
end
