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
- PvP 对决(`PvP = On`):使用游戏自带的格挡、弹反和闪避;弹反会让攻击者硬直;败者死亡
- 游戏水墨风格的搭档罗盘、搭档提示,倒下后可观战搭档
- 可选的 `Secret` 密码,为每个数据包签名;支持 UU 加速器、Tailscale、Hamachi、Radmin、ZeroTier 和 Steam(测试版)
- 不需要安装 Python:联机程序运行在游戏内部

## 快速开始

1. 双方都安装 [UE4SS for Phantom Blade Zero](https://www.nexusmods.com/phantombladezero/mods/5),以及一款虚拟局域网工具(UU 加速器联机功能、Tailscale 等)。
2. 把发布的压缩包解压到游戏的 `PBZ` 文件夹。
3. 编辑 `platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini`:房主设置 `Role = Host`,客人把 `HostAddress` 设为房主的虚拟局域网 IP。
4. 启动游戏并读取存档,房主先进。联机会自动开始。

目前是早期版本,支持两名玩家。

## 基本原则

- **不绕过 DRM。** 幻影契约不碰 Denuvo,也不修改游戏的可执行文件。一切都通过 UE4SS 加载,运行在正版游戏之内。
- 每位玩家都需要拥有自己的游戏。
- 本项目不包含任何游戏文件或素材。

## 致谢

- **[appdoze](https://github.com/appdoze)**:联机中继的安全审查和代码
- **Vercadi**:制作了 UE4SS for Phantom Blade Zero,让这款游戏的模组制作成为可能
- **UE4SS 团队**([RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS))
- **S-GAME 及游戏开发者**:《影之刃零》

*粉丝制作的模组,与 S-GAME 无关,也未获其认可。*
