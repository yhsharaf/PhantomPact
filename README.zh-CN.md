<p align="center">
  <img src="art/phantom-pact-banner-1300x372.png" alt="幻影契约 Phantom Pact:《影之刃零》线上联机模组" width="100%">
</p>

# 幻影契约(Phantom Pact):《影之刃零》线上联机模组

[English](README.md) | 简体中文

幻影契约(Phantom Pact)为《影之刃零》加入线上双人联机。两名玩家各自运行自己的游戏、保留自己的存档,模组把两个世界连接起来:你们能看到彼此,一起对付同样的敌人和首领,共享战利品和尘,并一同在钟旁休息。游戏世界以房主为准,搭档加入其中。

**下载:**[最新版本](https://github.com/yhsharaf/PhantomPact/releases/latest) · **安装和游玩:**[INSTALL.zh-CN.md](INSTALL.zh-CN.md) · **发现问题?**[提交 Issue](https://github.com/yhsharaf/PhantomPact/issues/new/choose)

## 功能

- 实时看到搭档的魂,包括移动、攻击、闪避和受击反应
- 两个世界的敌人同步,血量、架势和处决都是共享的
- 搭档的攻击在房主的世界同样有效,可以一起打同一个敌人
- 共享首领战:两名玩家都能看到首领血条和场地雾墙
- 共享战利品和尘:任何一方拾取或获得,双方都有
- 共享休息:在钟旁休息后,双方的敌人都会刷新
- 《艾尔登法环》式的联机难度:一起游玩时,敌人和首领的血量、架势更高
- PvP 比赛(F6,1.7.0 新增):决斗(三局两胜)和死斗,一对一或最多六人分两队,在游戏自己的四个首领场地或房主所在的地方进行。对所有人都公平:同样的身体、自选的 30 级武器、同一个葫芦喝三口、水墨笔触的倒数、血条、可选的限时,还能用首领的招式终结败者。比赛中的一切都不会存档,结束后全部还原(详见 [docs/PVP.md](docs/PVP.md),英文)
- PvPvE(更多 > PvPvE):在开放世界和搭档交手,敌人照样在场:使用游戏自带的格挡、弹反和闪避;弹反会让攻击者硬直;败者死亡
- 游戏水墨风格的搭档罗盘、搭档提示,倒下后可观战搭档
- 可选的 `Secret` 密码,为每个数据包签名;支持 UU 加速器、Tailscale、Hamachi、Radmin、ZeroTier 和 Steam(测试版)
- 本地双人(分屏,测试中):同一台电脑两名玩家,各用一个手柄,或键鼠加手柄。按 F5,在“更多”里把“模式”设为“本地分屏”,然后重启游戏(或设置 `Role = Local`)。玩家 2 可以自己攀爬、开宝箱、敲钟、喝葫芦、战斗;敌人会发现并攻击单独行动的玩家 2;菜单和游戏界面双方共用;Boss 血条也显示在玩家 2 的半屏。游戏中按 F4 打开面板,设置分屏方式和手柄。详见 docs/LOCAL_COOP.md(英文)。
- 不需要安装 Python:联机程序运行在游戏内部

## 快速开始

1. 双方都安装 [UE4SS for Phantom Blade Zero](https://www.nexusmods.com/phantombladezero/mods/5),以及一款虚拟局域网工具(UU 加速器联机功能、Tailscale 等)。
2. 把发布的压缩包解压到游戏的 `PBZ` 文件夹。
3. 编辑 `platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini`:房主设置 `Role = Host`,客人设置 `Role = Guest`,并把 `HostAddress` 设为房主的虚拟局域网 IP。
4. 启动游戏并读取存档,房主先进。联机会自动开始。也可以在游戏中按 F5 打开联机面板,直接开房或加入,不用改文件。

目前是早期版本,支持两名玩家。4 人模式为测试版,6 人模式为实验版:房主在 F5 面板“更多”的“人数”里选择后,最多三名或五名队友可以加入。五人或六人时,每个敌人和首领都会有一个红眼青色的幽灵双生,详见 [INSTALL.zh-CN.md](INSTALL.zh-CN.md#4-人模式测试版和-6-人模式实验版)。

双方必须使用相同版本:1.5.0 换了新的连接方式,1.4.1 及更早的版本无法与它连接。连不上或感觉卡顿时,请看 [INSTALL.zh-CN.md](INSTALL.zh-CN.md#连接问题) 的“连接问题”一节。

## 基本原则

- **不绕过 DRM。** 幻影契约不碰 Denuvo,也不修改游戏的可执行文件。一切都通过 UE4SS 加载,运行在正版游戏之内。
- 每位玩家都需要拥有自己的游戏。
- 本项目不包含任何游戏文件或素材。

## 致谢

- **[appdoze](https://github.com/appdoze)**:联机中继的安全审查和代码
- **[EXACG](https://github.com/EXACG)**:4 人模式的设计和代码(PR #11):由房主转发玩家数据,每位队友各有幽灵、指南针标记、地图标记和提示,敌人生命随玩家人数增加,`units` 实机检查,以及事件处理函数检查
- **Vercadi**:制作了 UE4SS for Phantom Blade Zero,让这款游戏的模组制作成为可能
- **UE4SS 团队**([RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS))
- **S-GAME 及游戏开发者**:《影之刃零》

*粉丝制作的模组,与 S-GAME 无关,也未获其认可。*
