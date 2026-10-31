# 幻影契约(Phantom Pact)1.4.1:《影之刃零》线上联机模组

和朋友一起玩主线:你们能看到彼此,对付同样的敌人和首领,共享战利品、尘和钟旁休息。敌人、首领和死亡以房主的世界为准,客人的世界跟随。

粉丝制作,非官方。每位玩家都需要在 Steam 上拥有自己的游戏。不修改、不分发任何游戏文件。

**发现问题?** 请到 Nexus Mods 的 Bugs 页面发帖,或在 https://github.com/yhsharaf/PhantomPact/issues 提交 Issue,写明发生了什么(房主还是客人、哪个区域或首领),并附上 `ue4ss\UE4SS.log`。

## 需要准备(双方都要)

1. Steam 上的《影之刃零》。
2. Vercadi 制作的 **UE4SS for Phantom Blade Zero**(Nexus Mods),安装到 `PBZ\platform\steam`。
3. 一款虚拟局域网工具,双方连到同一网络:**UU 加速器的联机功能**、Tailscale、Hamachi、Radmin 或 ZeroTier 都可以。

不需要安装 Python:从 1.4 起,联机程序运行在游戏内部(`PBZCoop\dlls\main.dll`),源代码在 GitHub 仓库的 `native/` 目录。

## 安装(双方都要)

1. 打开游戏文件夹:Steam > 右键点击游戏 > 管理 > 浏览本地文件。
2. 把压缩包里的所有内容解压到这个文件夹(`PBZ` 文件夹),提示合并文件夹时选择“是”。模组会放到 `platform\steam\ue4ss\Mods\PBZCoop`。
3. 用记事本打开 `platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini`:
   - **房主:** 把 `Role = Guest` 改成 `Role = Host`
   - **客人:** 把 `HostAddress` 设为房主在虚拟局域网工具里显示的 IP 地址
   - **使用 UU 加速器或 ZeroTier 时:** 房主还要设置 `AllowAnyAddress = On`。保留 `Connect = Tailscale` 即可,它只表示“通过 IP 连接”。
4. 启动游戏并读取存档,房主先进。进入游戏世界后联机会自动开始。Windows 询问时,房主必须点击**允许**,让游戏通过防火墙。

UE4SS 控制台会显示 `Phantom Pact Host: co-op on`(或 Guest),连接成功后 `ue4ss\Mods\PBZCoop\net_status.txt` 会显示 `connected=yes`。

- **更新:** 把新版本解压覆盖旧版本,然后重新设置 `Role` 和 `HostAddress`。
- **单人游玩:** 设置 `Role = Off`。
- **卸载:** 删除 `platform\steam\ue4ss\Mods\PBZCoop` 文件夹。

## 其他连接方式

- **Steam:** 双方都设置 `Connect = Steam`,客人会加入正在做房主的 Steam 好友,不需要虚拟局域网。双方必须是 Steam 好友。客人的 `HostAddress` 留空(或填房主的 Steam 名称),不要填 IP 地址。
- **Secret(可选):** 在两台电脑的 `Secret =` 里填相同的密码,每个数据包都会被签名,网络上的其他人无法加入。使用 `AllowAnyAddress = On` 时建议设置。

## 屏幕显示

- **搭档罗盘:** 屏幕顶部的线上有一枚银色印章,显示搭档的方向。用 `PartnerCompass = Off` 关闭。
- **提示:** 搭档连接、掉线、倒下或走远时会有简短提示。
- **死亡时:** 几秒后镜头会跟随搭档,直到你重生。

## 联机难度

和《艾尔登法环》一样,有搭档时敌人和首领会更强:默认 150% 血量、130% 架势。可在 `PhantomPact.ini` 修改 `CoopEnemyHealth` 和 `CoopEnemyPosture`(百分比,100 为原版)。双方应使用相同数值。

## PvP(对决)

双方都在 `PhantomPact.ini` 设置 `PvP = On`,搭档就成为可以交手的对手:

- 对方的攻击通过游戏自身的战斗系统命中你:**格挡**(按住防御键)消耗架势,时机准确的**弹反**(命中前轻按防御键)不消耗,闪避照常有效。
- 弹反的奖励和对付首领时一样:攻击者硬直并损失架势(`PvPParryPosture`,默认 60)。
- 败者真的死亡,并在钟旁重生,和普通死亡一样。
- 双方伤害相同,胜负取决于技术。`PvPDamage` 调整你受到的伤害(100 为原版)。

PvP 暂不支持处决(架势被破只会硬直)。

## 须知

- 敌人是同一场战斗:由房主的游戏控制,客人看到并对付的是同样的敌人。敌人的攻击在两台电脑上都正常生效,所以格挡、弹反和闪避都可以使用。
- 首领战:一方开始首领战时,另一方会被带入战场。准备开始时请靠近彼此:离房主较远时,房主电脑上没有加载的敌人会在客人这边各自行动。
- 搭档消失时,可能是倒下了、在过场动画中、在其他地图或掉线了,之后会回来。
- 客人在首领战中死亡时,房主的战斗继续;房主获胜对双方都算数。
- 暂不共享:过场动画、对话、消费尘、任务和剧情进度。
- 一起游玩时不要按 Ctrl+R(UE4SS 热重载),可能导致游戏崩溃。需要时请重启游戏。

## 常见问题

- **没有 “co-op on” 这一行:** 检查 `PhantomPact.ini`(Role,客人还要检查 HostAddress)。UE4SS 日志会写明缺少什么。
- **“dlls\main.dll isn't running”:** 杀毒软件可能删除了它。重新解压压缩包并允许该文件,然后重启游戏。如果装有 Python 3,模组会改用 Python。
- **模组文件夹里出现 `relay_error.txt`:** 连接无法启动,文件里写明了原因(例如端口被占用)。提交问题时请附上它。
- **`connected=no`:** 双方都连上虚拟局域网了吗?客人的 `HostAddress` 是否正确?Windows 防火墙必须允许游戏使用专用网络(房主第一次游玩时 Windows 会询问,请点击允许)。如果当时点了取消,请在 Windows 防火墙设置里允许 `PBZ.exe`。
- **完全没有 `[PBZCoop] Loaded` 这一行:** UE4SS 没有安装在 `PBZ\platform\steam`,或模组文件夹不在 `platform\steam\ue4ss\Mods\PBZCoop`。
