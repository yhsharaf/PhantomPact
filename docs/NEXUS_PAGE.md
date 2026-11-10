# Nexus Mods page: Phantom Pact

Not posted. For the user to read first, and it goes up with the 1.5.0 download: it describes things 1.4.1 doesn't have.

## Name and summary

Phantom Pact - Online Co-op

Phantom Blade Zero is single-player. Phantom Pact lets a friend join your world: two Souls, one campaign.

## Description

BBCode, for the description field. IMAGE-1 to IMAGE-6 are the six pictures, in that order: put the address of each one in
once they're uploaded. The red is `#ff2222`, for headings and links: the old links' `#ff0000`, a little brighter (3.8:1 on
Nexus's dark page, against 3.6:1, and 2.5:1 for the old headings' `#cc0000`). Headings are one size up from the old page.

```bbcode
[center][size=6][b]PHANTOM PACT ⚔️[/b][/size]
[size=4][i]Online Co-op For Phantom Blade Zero - 2 Players, 4 In Beta[/i][/size][/center]

Phantom Pact adds online co-op to Phantom Blade Zero. Each player runs their own game and keeps their own save, and Phantom Pact links the worlds: you see each other, fight the same enemies, take on bosses as a team, share loot and dust, and rest at bells together. The host’s world leads, and your partner joins in.

Open contribution, built by the community for the community. Let’s push it forward and fix bugs together: [url=https://github.com/yhsharaf/PhantomPact][color=#ff2222]yhsharaf/PhantomPact[/color][/url]

[line]

[color=#ff2222][size=5][b]How It Works[/b][/size][/color]

[list]
[*]Press [b]F5[/b] in the game, pick [b]Steam[/b], [b]Tailscale[/b] or [b]Other network[/b], then press [b]HOST[/b] or [b]GUEST[/b]. No text file and no restart.
[*]Each player loads [b]their own save[/b]. Joining takes you to the host once, even on another map.
[*]A tip at the bottom of the screen says [b]“partner connected”[/b] when you’re linked. The compass at the top shows which way your partner is.
[/list]

[line]

[color=#ff2222][size=5][b]Installation Instructions[/b][/size][/color]

Everyone who plays does this. To find the game folder: Steam > right-click the game > Manage > Browse local files.

[b]1. Install UE4SS[/b]
Get [url=https://www.nexusmods.com/phantombladezero/mods/5][color=#ff2222]UE4SS for Phantom Blade Zero[/color][/url]. Put [b]dwmapi.dll[/b] and the [b]ue4ss[/b] folder in [b]platform\steam[/b], next to PBZ.exe.

[img]IMAGE-1[/img]

[b]2. Extract Phantom Pact[/b]
Extract everything in the Phantom Pact zip into the game folder, the one with [b]platform[/b], [b]ProjectPBZ[/b] and [b]steam[/b] in it, not next to PBZ.exe. Say yes to merging folders.

[img]IMAGE-2[/img]

[b]3. Check It Landed[/b]
You should now have a [b]PBZCoop[/b] folder in [b]platform\steam\ue4ss\Mods[/b].

[img]IMAGE-3[/img]

[b]4. Connect[/b]
Start the game and load your saves, the host first, then follow the F5 tutorial below.
The first time you host, Windows asks whether the game may use the network: click [b]Allow[/b]. That window can open behind the game, so Alt+Tab if the guest can’t connect.

[b]Updating:[/b] everyone extracts the new version over the old one, then presses HOST or GUEST in F5 again.
[b]Playing alone:[/b] press [b]LEAVE[/b] in F5.
[b]To uninstall:[/b] delete [b]platform\steam\ue4ss\Mods\PBZCoop[/b] from the game folder.

[line]

[color=#ff2222][size=5][b]F5 Panel Tutorial[/b][/size][/color]

Press [b]F5[/b] once you’re in the world, on both PCs. The game doesn’t pause, so open it somewhere safe.

[img]IMAGE-4[/img]

[list=1]
[*][b]Language:[/b] [b]English[/b] or [b]中文[/b] at the top changes the panel and the co-op messages.
[*][b]Connect Through:[/b] pick the same one on both PCs. [b]Steam[/b] needs no setup. For [b]Tailscale[/b] or [b]Other network[/b], the host sends their address to the guest, who copies it and presses [b]Paste address[/b].
[*][b]Password (optional):[/b] copy the same password on both PCs and press [b]Paste password[/b] before you connect.
[*][b]HOST:[/b] one player presses it, and [b]Status[/b] says it’s waiting for a partner.
[*][b]GUEST:[/b] the other player presses it. Status shows who you’re connected to and your ping, and you’re taken to the host.
[*][b]MORE:[/b] TP > PARTNER, PvP, the partner compass, your partner on the map, Steam Direct, 4 Players and Mode.
[*][b]LEAVE:[/b] ends co-op. Your choices are kept for the next start.
[/list]

Press [b]Esc[/b], [b]F5[/b] or the [b]X[/b] to close the panel.

[line]

[color=#ff2222][size=5][b]Ways To Connect[/b][/size][/color]

[list]
[*][b]Steam:[/b] nothing to set up. You must be Steam friends, and the host must show as in the game, so not Invisible.
[*][b]Tailscale:[/b] with [url=https://tailscale.com][color=#ff2222]Tailscale[/color][/url], everyone signs in to the same network. The guest copies the host’s address and presses [b]Paste address[/b]. This also covers Hamachi, Radmin and a home network.
[*][b]Other network:[/b] for ZeroTier and UU Accelerator, with the host’s address pasted the same way.
[*][b]Prefer a text file?[/b] Open platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini in Notepad. Host: [b]Role = Host[/b]. Guest: [b]Role = Guest[/b], and [b]HostAddress[/b] set to the host’s address.
[/list]

[line]

[color=#ff2222][size=5][b]Main Features[/b][/size][/color]

[list]
[*]See your partner’s Soul live, with their attacks, guard, skills and hit reactions
[*]Shared enemies: the host’s game runs them, and you both see and fight the same ones
[*]Shared boss fights, with the boss health bar and fog walls for both of you
[*]Boss fights wait for everyone: die and you watch your partner until it’s over. Join during one and you watch, then go to them
[*]Enemies stay on one of you for about 15 seconds, then turn on the other if they’ve been hitting it
[*]Everything’s shared: what one of you gets from a chest, a pile or the ground, the other gets too. What you buy or make stays yours
[*]Shared dust and bell rests
[*]The game doesn’t pause while you’re linked, in the F5 panel or the game’s own menu: enemies keep coming
[*]Partner compass, your partner on the map, and tips when they connect, go down or wander off
[*]Elden Ring–style co-op difficulty: enemies and bosses get 50% more health and 30% more posture with a partner, bosses twice their guard bar, and super armour so two players can't stun-lock them
[*]PvP duels with the game’s own block, parry and dodge: turn it on under [b]MORE[/b] in F5
[/list]

[line]

[color=#ff2222][size=5][b]4 Players (Beta)[/b][/size][/color]

The host turns it on before pressing HOST: [b]F5 > MORE > 4 PLAYERS (Beta) > ON[/b]. Up to 3 guests can join, and OFF is the normal 2 players. Enemies and bosses get 50% more health for each person connected. PvP stays off.

[img]IMAGE-5[/img]

This is a beta: four real players haven’t played this version together yet. Please tell us how it goes in the Bugs tab.

[line]

[color=#ff2222][size=5][b]Two Players On One PC (In Testing)[/b][/size][/color]

Split-screen local co-op is in the same download, with no internet or second PC needed. Each player uses a pad, or player 1 uses the keyboard and mouse and player 2 a pad. You share one save, backpack and dust.

[b]1. Turn On Local Mode[/b]
Press [b]F5 > MORE > Mode > LOCAL[/b] and restart the game. Or open platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini in Notepad and set [b]Role = Local[/b]. To go back, press [b]MULTIPLAYER[/b] in the F4 panel.

[b]2. Set Up Your Pads[/b]
PlayStation pads need these steps, with one pad or two. Without them the game sends every pad to player 1.

[list=1]
[*][b]Turn off Steam Input:[/b] in Steam, right-click the game > Properties > Controller, then pick [b]Disable Steam Input[/b].
[*][b]Install [url=https://github.com/schmaldeo/DS4Windows/releases][color=#ff2222]DS4Windows[/color][/url]:[/b] connect your pads and leave it running. The game then sees them as Xbox pads.
[*][b]Install [url=https://github.com/nefarius/HidHide/releases][color=#ff2222]HidHide[/color][/url]:[/b] this stops the game seeing the real pads as well. Open it, add DS4Windows.exe under [b]Applications[/b], then on the [b]Devices[/b] tab tick your pads and [b]Enable device hiding[/b].
[*][b]Check DS4Windows:[/b] the [b]Ex[/b] column should show a tick for each pad. If it doesn’t, reconnect the pads.
[/list]

Xbox pads shouldn’t need any of this, but we haven’t tested them yet.

[b]3. Play[/b]
Start the game and press CONTINUE. Player 2 appears beside you within a few seconds. Press [b]F4[/b], hold a button on each pad to light up its card, drag the cards onto the players and press [b]APPLY[/b]. The zip’s [b]Phantom Pact - LOCAL CO-OP.md[/b] has player 2’s controls.

[img]IMAGE-6[/img]

Online co-op needs none of these pad steps. If your pads stop working in other games, turn off [b]Enable device hiding[/b] in HidHide. A game update can break two-pad play until the mod is updated.

[line]

[color=#ff2222][size=5][b]Requirements[/b][/size][/color]

[list]
[*]Phantom Blade Zero on Steam, for every player
[*][url=https://www.nexusmods.com/phantombladezero/mods/5][color=#ff2222]UE4SS for Phantom Blade Zero[/color][/url] 1.0.1 by Vercadi, for every player
[*]Everyone on the same Phantom Pact version: 1.4.1 or older can’t connect to 1.5.0
[*]No Python needed: the connection runs inside the game
[/list]

[line]

[color=#ff2222][size=5][b]Good To Know[/b][/size][/color]

[list]
[*]The host leads into new areas and boss arenas. Stay close when you’re about to start a boss
[*]Cutscenes, dialogue, spending dust, quests and story progress aren’t shared yet
[*]Don’t press Ctrl+R (UE4SS hot reload) while playing together: restart the game instead
[/list]

[line]

[color=#ff2222][size=5][b]Not Connecting?[/b][/size][/color]

[list]
[*]Did the host allow the game through Windows Firewall? That window can open behind the game
[*]The guide in the zip, Phantom Pact - INSTALL.md, has a Connection problems section
[*]Still stuck: post your [b]ue4ss\UE4SS.log[/b], [b]ue4ss\Mods\PBZCoop\net_status.txt[/b] and [b]ue4ss\Mods\PBZCoop\relay_log.txt[/b] in the Bugs tab
[/list]

[line]

[color=#ff2222][size=5][b]Shoutouts[/b][/size][/color]

[list]
[*][b]Vercadi[/b], for [url=https://www.nexusmods.com/phantombladezero/mods/5][color=#ff2222]UE4SS for Phantom Blade Zero[/color][/url], which made modding this game possible
[*][b]EXACG[/b], for the 4-player work ([url=https://github.com/EXACG][color=#ff2222]EXACG on GitHub[/color][/url])
[*][b]appdoze[/b], for the security review and code ([url=https://github.com/appdoze][color=#ff2222]appdoze on GitHub[/color][/url])
[*][b]The UE4SS team[/b] ([url=https://github.com/UE4SS-RE/RE-UE4SS][color=#ff2222]RE-UE4SS on GitHub[/color][/url])
[*][b]S-GAME and the game’s developers[/b] for Phantom Blade Zero
[/list]

[line]

[color=#ff2222][size=5][b]简体中文[/b][/size][/color]

幻影契约(Phantom Pact)为《影之刃零》加入线上联机。每位玩家各自运行自己的游戏、保留自己的存档,模组把世界连接起来:你们能看到彼此,一起对付同样的敌人和首领,共享战利品和尘,并一同在钟旁休息。

[b]安装[/b]

每位玩家都要安装。打开游戏文件夹:Steam > 右键点击游戏 > 管理 > 浏览本地文件。上面的三张图对应下面的第 1 到第 3 步。

[list=1]
[*]安装 [url=https://www.nexusmods.com/phantombladezero/mods/5][color=#ff2222]UE4SS for Phantom Blade Zero[/color][/url]:把 [b]dwmapi.dll[/b] 和 [b]ue4ss[/b] 文件夹放进 [b]platform\steam[/b],和 PBZ.exe 放在一起。不需要安装 Python。
[*]把压缩包里的所有内容解压到游戏文件夹,也就是有 [b]platform[/b]、[b]ProjectPBZ[/b] 和 [b]steam[/b] 的那个文件夹,不是 PBZ.exe 所在的文件夹。提示合并文件夹时选择“是”。
[*]确认 [b]platform\steam\ue4ss\Mods[/b] 里有 [b]PBZCoop[/b] 文件夹。
[*]启动游戏并读取存档,房主先进,然后按下面的 F5 面板教程操作。
[*]第一次开房时,Windows 会询问游戏能否使用网络,请点击[b]允许[/b]。这个窗口可能在游戏后面,连不上时按 Alt+Tab 查看。
[/list]

[b]F5 面板教程[/b]

进入游戏世界后,两台电脑都按 [b]F5[/b]。游戏不会暂停,请在安全的地方打开。上面的第 4 张图就是这个面板。

[list=1]
[*][b]语言:[/b]顶部的 English 和中文可以切换面板和联机提示的语言。
[*][b]连接方式:[/b]两台电脑选择同一种。Steam 无需设置。使用 Tailscale 或其他网络时,房主把地址发给客人,客人复制后按[b]粘贴地址[/b]。UU 加速器和 ZeroTier 选其他网络。
[*][b]密码(可不设):[/b]连接前,两台电脑复制同一个密码,然后按[b]粘贴密码[/b]。
[*][b]开房:[/b]一方按下后,状态栏会显示正在等待队友。
[*][b]加入:[/b]另一方按下后,状态栏会显示连接的对象和延迟,然后你会被传送到房主身边。
[*][b]更多:[/b]传送到队友、PvP、队友指南针、地图上的队友、Steam 直连、4 人模式和模式。
[*][b]离开:[/b]结束联机。你的选择会保存到下次启动。
[/list]

按 [b]Esc[/b]、[b]F5[/b] 或 [b]X[/b] 关闭面板。

[b]4 人模式(测试版)[/b]

由房主在开房前打开:[b]F5 > 更多 > 4 人模式(测试版) > 开[/b]。最多 3 名队友可以加入,选“关”就是普通的两人联机。每多连接一个人,敌人和首领的生命增加 50%。PvP 保持关闭。这是测试版,这个版本还没有四名真实玩家一起玩过,欢迎在 Bugs 页面反馈。

[b]同一台电脑两个人玩(测试中)[/b]

本地分屏也在同一个下载里,不需要网络,也不需要第二台电脑。可以每人一个手柄,也可以玩家 1 用键盘鼠标、玩家 2 用手柄。你们共用一个存档、背包和尘。

[list=1]
[*]打开本地模式:按 [b]F5 > 更多 > 模式 > 本地分屏[/b],然后重启游戏。也可以用记事本打开 platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini,设置 [b]Role = Local[/b]。要切换回去,在 F4 面板里按 [b]MULTIPLAYER[/b]。
[*]使用 PlayStation 手柄时,无论一个还是两个,都要先做下面三步,否则游戏会把所有手柄都交给玩家 1。关闭 Steam 输入:在 Steam 中右键点击游戏 > 属性 > 控制器,选择[b]禁用 Steam 输入[/b]。
[*]安装 [url=https://github.com/schmaldeo/DS4Windows/releases][color=#ff2222]DS4Windows[/color][/url]:连接手柄并让它保持运行。
[*]安装 [url=https://github.com/nefarius/HidHide/releases][color=#ff2222]HidHide[/color][/url]:打开后在 [b]Applications[/b] 里添加 DS4Windows.exe,再到 [b]Devices[/b] 勾选你的手柄和 [b]Enable device hiding[/b]。然后确认 DS4Windows 的 [b]Ex[/b] 一列中每个手柄都有勾,没有的话请重新连接手柄。
[*]启动游戏,按 CONTINUE。几秒后玩家 2 会出现在身边。按 [b]F4[/b],按住每个手柄上的任意键点亮它的卡片,把卡片拖到玩家上,再按 [b]APPLY[/b]。玩家 2 的操作见压缩包里的 Phantom Pact - LOCAL CO-OP.md。
[/list]

Xbox 手柄应该不需要这些步骤,但我们还没有测试过。线上联机不需要这些手柄设置。如果手柄在其他游戏里不能用,请在 HidHide 里关闭 Enable device hiding。游戏更新后,双手柄可能无法使用,需要等模组更新。

[b]没有连接上?[/b]

确认房主已允许游戏通过 Windows 防火墙。更多内容见[url=https://github.com/yhsharaf/PhantomPact/blob/main/INSTALL.zh-CN.md][color=#ff2222]中文安装说明[/color][/url]。仍然不行,请在 Bugs 页面附上 ue4ss\UE4SS.log、ue4ss\Mods\PBZCoop\net_status.txt 和 ue4ss\Mods\PBZCoop\relay_log.txt。

[center][i]Fan-made mod, not affiliated with or endorsed by S-GAME.[/i][/center]
```
