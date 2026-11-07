# Release notes draft: Phantom Pact 1.7.0, the PvP update

Not posted. For the user to edit and post, on GitHub and Nexus.

Unproven, so not claimed below: boss copies taking next to no poise in the host's moves (468a4e1), and 1.6.7's
CoopBossPoise. On the bench (11-07) a thug's light-hit flinch didn't change with TakenReductionMultiplier_Poise at 1, 0.01
or 0, nor with Resistance_Poise at 9999; whether a boss's armour in its attacks reads them still needs a boss to test on.

## To post

**PvP matches (F6).** Real matches, fair for everyone, in the game's own boss arenas:

- Press F6: the host picks Duel (best of three rounds) or Death (one life), a clock (none, 60, 90 or 120 s a round) and
  the arena: the Crimson Forest (YuCong), Hua Qianxiao's stage, the Gold-Masked One's gorge, Mu Xiaokui's meadow, or Here,
  where the host stands. A boss's arena opens once every player has beaten that boss
- Pick your loadout once and it's kept: two weapons and two Phantom Edges, any in the game, owned or not
- One on one, or two teams of up to six (Crimson and Azure): everyone picks a team and presses READY
- Everyone fights with the same body: every skill node on, the same health and attack, every weapon at level 30, three
  drinks from the same gourd for the whole match. Every blow does half the usual damage: about six clean hits to bring
  someone down, so parries and reads decide it
- The arena's fog walls go up and there are no monsters. A countdown in brush strokes, 三 二 一, then 斗
- Every foe on the game's own boss health bar, with their name, the score and the clock over it; round and match banners
- In a team match your teammates' health shows over your own bar, in its look: the health a blow takes stays in red a moment
  and drains, and a fallen teammate's bar empties
- Parries are the game's own deflect, timed: raise your guard as their blow comes and it's turned aside for nothing, your
  foe staggers and loses posture, and they see your blade turn theirs aside. A guard already held only blocks. Your guard
  and your dodges show on the other screens as you make them: a blow into your guard no longer looks like it landed there
- The blow that wins the match plays in slow motion and leaves the losers on their feet, dazed. The winners then have about
  five seconds to finish them with F: every screen cuts to a camera beside the two that keeps clear of rocks and walls, and
  the winner finishes them with the arena's boss's own move (YuCong's lunge, Hua Qianxiao's drunken slide and cut, the
  Gold-Masked One's lunge and upward cut, Mu Xiaokui's twin-blade dash; Here draws one of the four), run in from where its
  blow lands on them. The moment it lands slows nearly to a stop, and the loser dies the way the game shows a death
- The winners get a golden 生还, the losers the game's red 殒命, both shown the same way, and everyone goes back where they
  were with their own weapons, levels, gourd and skills. Nothing in a match is saved
- The network carries only the players in a match (no enemy traffic), moves are sent the frame they start, and a perfect
  dodge's slow motion is off in a match, so every game runs at the same speed

**PvPvE.** The old PvP switch under MORE is now called PvPvE: fighting each other in the open world, enemies and all. It
works as before.

**Co-op fixes, from your reports:**

- Bosses fight back: a partner's hits no longer stun-lock a boss. It flinches only when its posture breaks, never in the
  middle of its own attack
- A boss turns to whoever is pressing it harder: a turn the game didn't make no longer keeps it on the host for another 10 s
- Bells: joining a host further along no longer lights every bell they have (Pangzhen's all lit, fast travel everywhere).
  A host's bell lights for you when you walk up to it
- Dying in a boss fight while your partner fights on: you stay down until it's over, and the boss is no longer reset to
  full health a few seconds later (the host's death ended the guest's copy of the fight). A boss's phase scene or an
  execution no longer ends the wait either
- Joining while the host is in a boss fight: F3 takes you in right away, and after 30 s (was 3 minutes) you're free to move
  anyway. No more standing there with no control
- Story bosses: a boss your partner started first stays your fight when your own scene brings it in; Xiaoxue getting up
  again no longer vanishes for the guest; a leftover copy no longer blocks the bell by the arena ("in combat")
- Enemies that turned invisible after a teleport or a bell come back, and a mob emptied by the guest no longer stands
  frozen and hittable for seconds, or now and then can't be killed at all. The late blows of a long execution, and your
  own lingering shots, count as your hits
- A teammate's drink glow and other copied effects end when they should
- A QTE you get stuck in during a boss's scene lets you go, and the host skipping a scene no longer ends yours mid-QTE
- Items lying where you stood no longer vanish for your partner when you teleport, respawn or rest away from them
- In PvP, a match no longer resets your skill tree (it could take your nodes and lock talisman slots), and you come home
  with your own attack, not the match's

Both players need 1.7.0. Thanks to shilover (Rakka) for the ideas in issue #13, and to everyone who sent reports and logs.

## 中文

**PvP 比赛(F6)。** 对所有人都公平的正式比赛,在游戏自己的首领场地进行:

- 按 F6:房主选择决斗(三局两胜)或死斗(只有一条命)、每局限时(不限时、60、90 或 120 秒)和场地:赤林(余聪)、花千笑之台、
  金面人之谷、木小葵之野,或者此地(房主所在的地方)。所有玩家都打败了该首领后,这个首领的场地才会开放
- 配装选一次就会保存:两把武器和两件杀器,游戏里的任意一件,有没有都可以
- 一对一,或最多六人分成赤队和青队:每个人选队伍,然后按准备
- 所有人用同样的身体作战:技能全部点满,生命和攻击相同,所有武器都是 30 级,整场比赛同一个葫芦只能喝三口。每一击的伤害是平时的一半:大约六次干净的命中才能击倒对手,胜负取决于弹反和读招
- 场地的雾墙升起,没有怪物。水墨笔触的倒数 三 二 一,然后 斗
- 每个对手都显示在游戏自己的首领血条上,上方写着名字、比分和时间;每局和整场的结果横幅
- 组队比赛中,队友的血条显示在你自己的血条上方,样式相同:被打掉的血会以红色停留片刻再慢慢褪去,倒下的队友血条会清空
- 弹反就是游戏自己的弹刀,讲究时机:在对方的攻击到来时举起架势,这一击就会被无损地弹开,对手会失衡并损失架势,对方也会看到你的刀弹开了他的刀。一直举着的架势只是格挡。你的架势和闪避会在你做出的那一刻显示在其他人的画面上:打在你架势上的攻击不会再看起来像是命中了
- 决定胜负的一击会慢放,败者不会倒下,而是站着失去架势。胜者有大约五秒钟按 F 终结对手:所有画面切到两人身旁的镜头(镜头会避开岩石和墙壁),胜者用该场地首领自己的招式终结对手(余聪的突刺、花千笑的醉步滑行与斩击、金面人的突刺与上挑、木小葵的双刀冲刺;此地会从四招中抽一招),并从让这一招正好打中对手的位置出招。命中的一刻几乎静止,败者以游戏自己的死亡方式倒下
- 胜者看到金色的“生还”,败者看到游戏自己的红色“殒命”,两者以同样的方式呈现,所有人回到原来的地方,武器、等级、葫芦和技能都会还原。比赛中的一切都不会存档
- 比赛中网络只传送玩家的数据(没有敌人的数据),招式在开始的那一帧就会发出;比赛中没有完美闪避的慢动作,所有人的游戏以同样的速度运行

**PvPvE。** “更多”里原来的 PvP 开关现在叫 PvPvE:在开放世界交手,敌人照样在场,玩法不变。

**合作修复(来自大家的反馈):**

- 首领会还手了:队友的攻击不会再让首领一直被打断。只有架势被打破时才会硬直,不会在它自己出招时被打断
- 首领会转向压制它更狠的人:游戏没有执行的转向不会再让它多盯房主 10 秒
- 钟:加入进度更靠前的房主时,不会再点亮房主所有的钟(庞镇全部点亮、到处都能传送)。房主点亮的钟要等你走到旁边才会为你点亮
- 队友还在首领战中时你倒下:你会一直等到战斗结束,首领不会再在几秒后回满血(房主的死亡曾结束客人那边的战斗)。首领的转阶段动画或处决也不会结束等待
- 房主在首领战中时加入:按 F3 可立即加入,30 秒后(原来是 3 分钟)无论如何都可以自由行动,不会再站着无法操作
- 剧情首领:队友先开始的首领战,在你自己的剧情把首领带出来时仍然是你的战斗;小雪重新站起来后不会在客人那边消失;残留的复制体不会再挡住场地旁的钟(“战斗中”)
- 传送或坐火后隐身的敌人会回来;客人打空血条的小怪不会再僵在原地几秒还能被打,也不会偶尔怎么都打不死。长处决的后几下和你自己残留的攻击也算作你的命中
- 队友喝药的光效等复制的特效会按时结束
- 在首领的过场中卡住的 QTE 会放开你,房主跳过过场时也不会在你 QTE 进行中结束你的过场
- 你传送、复活或坐火离开后,你身边的物品不会再在队友那边消失
- PvP 比赛不会再重置你的技能树(之前可能让你失去节点并锁住护符槽),回来后的攻击力也是你自己的,而不是比赛中的

双方都需要 1.7.0。感谢 shilover(Rakka)在 issue #13 中提出的想法,也感谢所有提交反馈和日志的玩家。
