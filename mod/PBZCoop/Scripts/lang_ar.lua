-- The online mode's words in Arabic, for lang.lua: the same English lines (LINES) and pieces of lines (PARTS,
-- Lua patterns, applied in order) as its Chinese, with the Arabic put where the English's names and numbers go.
-- Made by tools/make_lang_ar.py from art/arabic.tsv, which the Arabic pictures come from too: don't edit this,
-- correct the tsv and run it again. Each row says its tsv id. The mod's author checks every line.
return {
    LINES = {
        -- the panel
        ["Not connected."] = "غير متصل.",  -- f5.words.not_connected
        ["Starting..."] = "جارٍ البدء...",  -- f5.words.starting
        ["Waiting for a partner."] = "بانتظار شريك.",  -- f5.words.waiting
        ["Looking for a Steam friend who's hosting..."] = "جارٍ البحث عن صديق على Steam يستضيف...",  -- f5.words.looking_steam
        ["Copy the host's address first, then press Paste."] = "انسخ عنوان المضيف أولًا، ثم اضغط «لصق العنوان».",  -- f5.words.paste_first
        ["Copy the password first, then press Paste password."] = "انسخ كلمة المرور أولًا، ثم اضغط «لصق كلمة المرور».",  -- f5.words.pw_first
        ["Password set. Your partner needs the same one."] = "تم تعيين كلمة المرور. يحتاج شريكك إلى كلمة المرور نفسها.",  -- f5.words.pw_set
        ["Password removed."] = "أُزيلت كلمة المرور.",  -- f5.words.pw_removed
        ["PhantomPact.ini: HostAddress isn't set. Put the host's Tailscale IP there, or use Steam."] = "لم يُعيَّن HostAddress في PhantomPact.ini. اكتب فيه عنوان IP الخاص بالمضيف على Tailscale، أو استخدم Steam.",  -- f5.words.ini_no_address
        ["PhantomPact.ini: HostAddress has a character that can't be used (\" % & | < > ^). Leave it empty to join any friend who's hosting."] = "يحتوي HostAddress في PhantomPact.ini على رمز غير مسموح به (\" % & | < > ^). اتركه فارغًا للانضمام إلى أي صديق يستضيف.",  -- f5.words.ini_bad_char
        ["this game update isn't tested with this Phantom Pact version; some co-op features may fail."] = "لم يُختبر تحديث اللعبة هذا مع إصدار Phantom Pact الحالي، وقد تتعطل بعض ميزات اللعب التعاوني.",  -- tip.conn.build
        ["Couldn't start the relay: dlls\\main.dll can't be reached. Reinstall Phantom Pact, check your antivirus didn't remove it, and use the UE4SS build from the install guide."] = "تعذّر تشغيل وحدة الاتصال: لا يمكن الوصول إلى dlls\\main.dll. أعد تثبيت Phantom Pact، وتأكد من أن برنامج مكافحة الفيروسات لم يحذفه، واستخدم إصدار UE4SS المذكور في دليل التثبيت.",  -- tip.conn.no_dll
        -- PvP (F6)
        ["Putting the last match back: a moment."] = "جارٍ إرجاعك من النزال السابق: انتظر لحظة.",  -- f6.words.restoring
        ["too late to finish them: the match is over."] = "فات أوان الإجهاز عليه: انتهى النزال.",  -- tip.pvp.too_late
        ["no talismans in a match: yours come back after it."] = "لا تمائم في النزال: ستعود إليك تمائمك بعده.",  -- tip.pvp.talismans
        -- the partner
        ["your partner is down."] = "سقط شريكك.",  -- tip.partner.down
        ["your partner is back."] = "عاد شريكك.",  -- tip.partner.back
        ["your partner is watching a cutscene."] = "يشاهد شريكك مشهدًا سينمائيًا.",  -- tip.partner.cutscene
        ["your partner rested at a bell: you'll join them."] = "استراح شريكك عند جرس: ستنتقل إليه.",  -- tip.partner.rest_join
        ["your partner rested at a bell: you're rested, and so is the boss."] = "استراح شريكك عند جرس، واستعدت عافيتك، وكذلك الزعيم.",  -- tip.partner.rest_boss
        ["your partner needs PvPvE on too, or their moves won't show here."] = "يجب أن يفعّل شريكك PvPvE أيضًا، وإلا فلن تظهر حركاته هنا.",  -- f5more.tip.pvpve_partner
        ["PvPvE on for everyone: the host's rules count for all."] = "فُعِّل PvPvE للجميع: قواعد المضيف تسري على كل اللاعبين.",  -- f5more.tip.pvpve_all
        ["partner disconnected."] = "انقطع اتصال شريكك.",  -- tip.conn.disconnected
        ["your partner turned co-op sync off."] = "أوقف شريكك مزامنة اللعب التعاوني.",  -- tip.partner.sync_off
        ["PvPvE is off with more than two players (F6 PvP has teams)."] = "مع 3 لاعبين أو أكثر يكون PvPvE معطّلًا (لكن PvP في F6 يدعم الفرق).",  -- f5more.tip.pvpve_party
        ["Local co-op starts the next time you start the game."] = "يبدأ اللعب التعاوني المحلي عند تشغيل اللعبة المرة القادمة.",  -- f5more.tip.local_next
        ["Only the host's Players setting counts."] = "إعداد «عدد اللاعبين» يحدده المضيف وحده.",  -- f5more.tip.players_host
        ["Only the host's setting counts."] = "المعتمد هو إعداد المضيف وحده.",  -- f5more.tip.host_setting
        ["Players: from your next Host (Leave, then Host)."] = "عدد اللاعبين: من استضافتك القادمة («مغادرة» ثم «استضافة»).",  -- f5more.tip.players_next
        ["Multiplayer starts the next time you start the game."] = "يبدأ اللعب عبر الإنترنت عند تشغيل اللعبة المرة القادمة.",  -- local.tip.multiplayer_next
        ["TP > PARTNER is off. Turn it on in MORE (F5)."] = "خيار «الانتقال إلى الشريك» معطّل. فعّله من «المزيد» (F5).",  -- tip.f3.tp_off
        ["couldn't reach your partner in time. TP > PARTNER in MORE (F5) can take you there."] = "تعذّر الوصول إلى شريكك في الوقت المحدد. خيار «الانتقال إلى الشريك» في «المزيد» (F5) ينقلك إليه.",  -- tip.f3.too_late
        ["no partner to go to yet."] = "لا يوجد شريك تنتقل إليه بعد.",  -- tip.f3.no_partner
        ["not now."] = "ليس الآن.",  -- tip.f3.not_now
        ["you're in the prologue: finish it first, or start a New Game and choose the game's own skip there."] = "أنت في المقدمة: أنهِها أولًا، أو ابدأ New Game واختر خيار التخطي في اللعبة نفسها.",  -- tip.f3.in_prologue
        ["to skip the prologue, start a New Game and choose the game's own skip there."] = "لتخطي المقدمة، ابدأ New Game واختر خيار التخطي في اللعبة نفسها.",  -- f5more.tip.skip_how
        ["you're past the prologue."] = "لقد تجاوزت المقدمة بالفعل.",  -- f5more.tip.past_prologue
        ["your partner is still in the prologue."] = "ما زال شريكك في المقدمة.",  -- tip.f3.partner_prologue
        ["your partner can't be joined right now."] = "لا يمكن الانتقال إلى شريكك الآن.",  -- tip.f3.cant_join
        ["your partner's position looks wrong."] = "يبدو أن موقع شريكك غير صحيح.",  -- tip.f3.position
        ["your partner's map isn't known yet."] = "خريطة شريكك غير معروفة بعد.",  -- tip.f3.map_unknown
        ["the game wouldn't go there."] = "رفضت اللعبة الانتقال إلى هناك.",  -- tip.f3.wouldnt_go
        -- revive
        ["you're down: you'll be back when the fight is over."] = "سقطت: ستعود حين ينتهي القتال.",  -- tip.boss.hold
        ["your partner is in a boss fight: you'll join them when it's over. F3 takes you in now."] = "شريكك في معركة زعيم: ستنتقل إليه حين ينتهي القتال. اضغط F3 لتدخل الآن.",  -- tip.boss.watching
        ["your partner is in a boss fight: press E at the black wall, or F3, to join."] = "شريكك في معركة زعيم: للانضمام، اضغط E عند جدار الضباب الأسود أو اضغط F3.",  -- tip.boss.wall_join
        ["the fight is taking long: you're free to move. F3 takes you to your partner."] = "طال القتال: يمكنك التحرك بحرية. اضغط F3 للانتقال إلى شريكك.",  -- tip.boss.taking_long
        ["your partner is in a boss fight: F3 takes you there, if you want to join."] = "شريكك في معركة زعيم: إن أردت الانضمام، اضغط F3 للانتقال إلى هناك.",  -- tip.boss.f3_join
        ["no ground past the wall here: try another part of it."] = "لا أرض خلف الجدار هنا: جرّب جزءًا آخر منه.",  -- tip.boss.no_ground
        ["your PC's clock and your partner's are over 2 minutes apart: set both to the right time."] = "تختلف ساعة جهازك عن ساعة جهاز شريكك بأكثر من دقيقتين: اضبط الساعتين على الوقت الصحيح.",  -- tip.conn.clock
        ["You're back on your feet."] = "نهضت من جديد.",  -- revive.tip.up
        ["You're down: your partner can strike you to bring you back."] = "سقطت: يستطيع شريكك إنعاشك بضربك.",  -- revive.tip.down
        ["Your partner is down: strike them to bring them back."] = "سقط شريكك: اضربه لإنعاشه.",  -- revive.tip.partner_down
        ["Your partner is back on their feet."] = "نهض شريكك من جديد.",  -- revive.tip.partner_up
        -- PvP (F6)
        ["Play online first (F5): PvP is between linked players."] = "العب عبر الإنترنت أولًا (F5): نزالات PvP بين اللاعبين المتصلين.",  -- f6.words.offline_short
        ["Play online first (F5): PvP is between linked players. Your loadout is kept for when you are."] = "العب عبر الإنترنت أولًا (F5): نزالات PvP بين اللاعبين المتصلين. يُحفظ عتادك لحين اتصالك.",  -- f6.words.offline
        ["The host starts the match."] = "المضيف هو من يبدأ النزال.",  -- f6.words.host_starts
        ["Nobody to fight: a partner needs to be linked."] = "لا يوجد من تقاتله: يجب أن يتصل شريك.",  -- f6.words.nobody
        ["Both teams need someone."] = "يحتاج كل فريق إلى لاعب واحد على الأقل.",  -- f6.words.both_teams
        ["Three a side at most: someone needs to change team."] = "ثلاثة لكل فريق على الأكثر: على أحدكم أن يغيّر فريقه.",  -- f6.words.three_a_side
        ["Everyone's ready: START when you are."] = "الجميع جاهزون: اضغط «ابدأ» متى شئت.",  -- f6.words.all_ready
        ["You're ready. The host starts the match."] = "أنت جاهز. المضيف هو من يبدأ النزال.",  -- f6.words.you_ready
        ["Set your loadout, pick a team, then READY."] = "جهّز عتادك واختر فريقًا، ثم اضغط «جاهز».",  -- f6.words.set_loadout
        ["Click one to take it; BACK keeps what you had."] = "انقر على سلاح لاختياره؛ «رجوع» يُبقي ما كان لديك.",  -- f6.words.pick
        ["In a match: LEAVE twice ends it for everyone."] = "أثناء النزال: اضغط «مغادرة» مرتين لإنهائه للجميع.",  -- f6.words.in_match
        ["can't get to the arena from here."] = "لا يمكن الوصول إلى الساحة من هنا.",  -- tip.pvp.no_arena
        ["press LEAVE again to end the match for everyone."] = "اضغط «مغادرة» مرة أخرى لإنهاء النزال للجميع.",  -- tip.pvp.press_leave
        ["get closer to a fallen foe to finish them."] = "اقترب من الخصم الساقط للإجهاز عليه.",  -- tip.pvp.get_closer
        ["a match was cut short by the game closing: back to where it began."] = "انقطع النزال لأن اللعبة أُغلقت: عدت إلى حيث بدأ.",  -- tip.pvp.cut_short
        ["the host sets the match."] = "إعدادات النزال يحددها المضيف.",  -- tip.pvp.host_sets
        ["two players: one team each."] = "لاعبان: لكلٍّ منهما فريق.",  -- tip.pvp.two_players
        ["the loadout changes for the next match."] = "تسري تغييرات العتاد في النزال التالي.",  -- tip.pvp.loadout_next
        -- the connection
        ["nobody has joined yet. Your partner needs Role = Guest and your address: two Hosts never find each other."] = "لم ينضم أحد بعد. يحتاج شريكك إلى Role = Guest وإلى عنوانك: إذا استضاف كلاكما فلن يجد أحدكما الآخر.",  -- tip.conn.nobody_joined
        ["packets refused: both PCs need the same Secret in PhantomPact.ini (or both none), and their clocks within two minutes of each other."] = "رُفض الاتصال: يجب أن تتطابق كلمة المرور (Secret) في PhantomPact.ini على الجهازين (أو تُترك فارغة على كليهما)، وأن يقل الفرق بين ساعتيهما عن دقيقتين.",  -- tip.conn.secret
        ["Steam is relaying this connection, which adds delay. A direct one needs SteamDirect = On on both PCs and routers that allow it."] = "يمر هذا الاتصال عبر وسيط من Steam، مما يزيد التأخير. الاتصال المباشر يحتاج إلى SteamDirect = On على الجهازين، وإلى راوترات تسمح به.",  -- tip.conn.steam_relay
        -- no Chinese: the tip's head (status.lua says it on its own), the partner, local co-op (F4)
        ["Phantom Pact: "] = "Phantom Pact: ",  -- tip.prefix
        ["partner connected, signed."] = "اتصل شريكك، والاتصال محمي بكلمة المرور.",  -- tip.conn.connected_signed
        ["partner connected."] = "اتصل شريكك.",  -- tip.conn.connected
        ["your partner finished a quest step you were on: done for you too."] = "أنهى شريكك مرحلة من المهمة كنت فيها، فاكتملت لك أيضًا.",  -- tip.partner.quest_step
        ["close the game's menu first, then press F4."] = "أغلق قائمة اللعبة أولًا، ثم اضغط F4.",  -- local.tip.close_menu
        ["press E or Circle at the black wall to join the fight."] = "اضغط E أو زر الدائرة عند جدار الضباب الأسود للانضمام إلى القتال.",  -- local.tip.wall
        ["player 2 joined."] = "انضم اللاعب 2.",  -- local.tip.p2_joined
        ["player 2's gourd is empty: rest at a bell."] = "قرعة الشفاء لدى اللاعب 2 فارغة: استرح عند جرس.",  -- local.tip.gourd_empty
        ["player 1 is on the left monitor, player 2 on the right one."] = "اللاعب 1 على الشاشة اليسرى، واللاعب 2 على الشاشة اليمنى.",  -- local.tip.mon_lr
        ["player 1 is on the top monitor, player 2 on the bottom one."] = "اللاعب 1 على الشاشة العليا، واللاعب 2 على الشاشة السفلى.",  -- local.tip.mon_tb
        ["two monitors: there's no monitor beside this one, so both players stay on this one."] = "وضع الشاشتين: لا توجد شاشة بجانب هذه الشاشة، لذا يبقى اللاعبان عليها.",  -- local.tip.mon_single
        ["two monitors need the game's display mode on Borderless or Windowed."] = "يحتاج وضع الشاشتين إلى ضبط وضع العرض في اللعبة على «نافذة بلا حدود» أو «نافذة».",  -- local.tip.mon_mode
        -- the match screen (arenaui.lua): the countdown's words, a foe's name before their slot, YOU before the score
        ["ONE"] = "واحد",  -- match.count.one
        ["TWO"] = "اثنان",  -- match.count.two
        ["THREE"] = "ثلاثة",  -- match.count.three
        ["FIGHT"] = "قتال!",  -- match.count.fight
        ["TIME'S UP"] = "انتهى الوقت",  -- match.timeup
        ["PLAYER "] = "اللاعب ",  -- match.foe.name
        ["YOU"] = "أنت",  -- match.foe.score
    },
    PARTS = {
        -- the panel's line: Connected to, then each piece with its own leading space
        { "^Connected to (%S+)%.", "متصل بـ %1." },  -- f5.words.connected
        { " Ping (%d+) ms%.", " البينغ %1 مللي ثانية." },  -- f5.words.ping
        { " Route: direct%.", " المسار: مباشر." },  -- f5.words.route_direct
        { " Route: relay%.", " المسار: عبر وسيط." },  -- f5.words.route_relay
        { "^Couldn't start: (.*)$", "تعذّر البدء: %1" },  -- f5.words.couldnt_start
        { "^Couldn't start the relay: net_start%.txt can't be written in (.+)$", "تعذّر تشغيل وحدة الاتصال: لا يمكن كتابة net_start.txt في %1" },  -- tip.conn.no_write
        { "^Looking for (.+)%.%.%.$", "جارٍ البحث عن %1..." },  -- f5.words.looking_for
        { "^Host address set to (.+)%.$", "تم تعيين عنوان المضيف: %1." },  -- f5.words.address_set
        -- the partner and the connection
        { "^your partner is on another map%.", "شريكك في خريطة أخرى." },  -- tip.partner.other_map
        { "^your partner is (%d+) m away%.", "شريكك على بُعد %1 متر." },  -- tip.partner.far
        { " F3 takes you there%.$", " اضغط F3 للانتقال إلى هناك." },  -- tip.partner.f3_there
        { "^partner connected %(ping (%d+) ms%), signed%.$", "اتصل شريكك (البينغ %1 مللي ثانية)، والاتصال محمي بكلمة المرور." },  -- tip.conn.connected_ping_signed
        { "^partner connected %(ping (%d+) ms%)%.$", "اتصل شريكك (البينغ %1 مللي ثانية)." },  -- tip.conn.connected_ping
        { "^your bag now has what your partner's has %((%d+) new%)%.$", "صارت حقيبتك تحوي ما في حقيبة شريكك (جديد: %1)." },  -- tip.partner.bag
        { "^co%-op couldn't start: (.*)$", "تعذّر بدء اللعب التعاوني: %1" },  -- tip.conn.couldnt_start
        { "^Steam couldn't connect: (.+)%. See Connection problems in the install guide%.$", "تعذّر اتصال Steam: %1. راجع «Connection problems» في دليل التثبيت." },  -- tip.conn.steam_couldnt
        { "^settings differ from your partner's: (.*)$", "تختلف إعداداتك عن إعدادات شريكك: %1" },  -- tip.conn.settings_differ
        { "^your partner's Phantom Pact %((.+)%) can't connect to (.+): both PCs need the same version%.$", "إصدار Phantom Pact لدى شريكك (%1) لا يمكنه الاتصال بإصدارك %2: يلزم الإصدار نفسه على الجهازين." },  -- tip.conn.version_cant
        { "1%.4%.1%-or%-older", "1.4.1 أو أقدم" },  -- term.version.older
        { "other%-protocol", "بروتوكول مختلف" },  -- term.version.other
        { "^your partner is on Phantom Pact (.+) and you're on (.+): use the same version, or enemies won't stay in step%.$", "شريكك يستخدم Phantom Pact %1 وأنت تستخدم %2: يجب استخدام الإصدار نفسه، وإلا فلن يبقى الأعداء متزامنين." },  -- tip.conn.version_diff
        { "^high ping %((%d+) ms%)%.", "البينغ مرتفع (%1 مللي ثانية)." },  -- tip.conn.high_ping
        { " On Tailscale, run \"tailscale ping\": via DERP means relayed%.$", " على Tailscale، شغّل «tailscale ping»: إن ظهر via DERP فالاتصال يمر عبر وسيط." },  -- tip.conn.tailscale_ping
        { "^no answer from the host %((.+)%)%. Check HostAddress and Port, that they're in the game on Role = Host, and the same Secret and Phantom Pact version on both PCs%.$", "لا رد من المضيف (%1). تحقق من HostAddress و Port، ومن أن المضيف في اللعبة على Role = Host، ومن تطابق كلمة المرور (Secret) وإصدار Phantom Pact على الجهازين." },  -- tip.conn.no_answer
        { "^no friend hosting found%..*$", "لم يُعثر على صديق يستضيف. يجب أن تكونا صديقين على Steam، وأن يضبط شريكك Role = Host و Connect = Steam دون أن يكون «غير مرئي» على Steam (أو ضع SteamID64 الخاص به في HostAddress)، وأن تتطابق كلمة المرور (Secret) وإصدار Phantom Pact على الجهازين." },  -- tip.conn.no_friend
        -- the relay's own errors, after the panel's head or a tip's (the two rows above that end in (.*)$)
        { "^تعذّر البدء: no system random numbers for the Secret$", "تعذّر البدء: لم يوفّر النظام أرقامًا عشوائية لكلمة المرور (Secret)" },  -- tip.relayerr.random
        { "^تعذّر البدء: Winsock didn't start$", "تعذّر البدء: فشل تشغيل Winsock" },  -- tip.relayerr.winsock
        { "^تعذّر البدء: couldn't open a UDP socket$", "تعذّر البدء: فشل فتح مقبس UDP" },  -- tip.relayerr.socket
        { "^تعذّر البدء: UDP port (%d+) is in use on this PC %(error (%d+)%): set another Port in PhantomPact%.ini on both PCs$", "تعذّر البدء: منفذ UDP رقم %1 قيد الاستخدام على هذا الجهاز (الخطأ %2): غيّر قيمة Port في PhantomPact.ini على الجهازين" },  -- tip.relayerr.port_in_use
        { "^تعذّر البدء: UDP port (%d+) can't be used %(error (%d+)%): set another Port in PhantomPact%.ini on both PCs$", "تعذّر البدء: لا يمكن استخدام منفذ UDP رقم %1 (الخطأ %2): غيّر قيمة Port في PhantomPact.ini على الجهازين" },  -- tip.relayerr.port_cant
        { "^تعذّر البدء: couldn't find the host address (.+)$", "تعذّر البدء: لم يُعثر على عنوان المضيف %1" },  -- tip.relayerr.no_host
        { "^تعذّر البدء: this game's Steam has no (.+)$", "تعذّر البدء: لا يحتوي Steam في هذه اللعبة على %1" },  -- tip.relayerr.steam_no_fn
        { "^تعذّر البدء: Steam isn't loaded in this game %(steam_api64%.dll%)$", "تعذّر البدء: لم يُحمَّل Steam في هذه اللعبة (steam_api64.dll)" },  -- tip.relayerr.steam_not_loaded
        { "^تعذّر البدء: Steam isn't ready: is it running and logged in%?$", "تعذّر البدء: لم يجهز Steam بعد: هل هو مفتوح وقد سجّلت الدخول إليه؟" },  -- tip.relayerr.steam_not_ready
        { "^تعذّر بدء اللعب التعاوني: no system random numbers for the Secret$", "تعذّر بدء اللعب التعاوني: لم يوفّر النظام أرقامًا عشوائية لكلمة المرور (Secret)" },  -- tip.relayerr.random
        { "^تعذّر بدء اللعب التعاوني: Winsock didn't start$", "تعذّر بدء اللعب التعاوني: فشل تشغيل Winsock" },  -- tip.relayerr.winsock
        { "^تعذّر بدء اللعب التعاوني: couldn't open a UDP socket$", "تعذّر بدء اللعب التعاوني: فشل فتح مقبس UDP" },  -- tip.relayerr.socket
        { "^تعذّر بدء اللعب التعاوني: UDP port (%d+) is in use on this PC %(error (%d+)%): set another Port in PhantomPact%.ini on both PCs$", "تعذّر بدء اللعب التعاوني: منفذ UDP رقم %1 قيد الاستخدام على هذا الجهاز (الخطأ %2): غيّر قيمة Port في PhantomPact.ini على الجهازين" },  -- tip.relayerr.port_in_use
        { "^تعذّر بدء اللعب التعاوني: UDP port (%d+) can't be used %(error (%d+)%): set another Port in PhantomPact%.ini on both PCs$", "تعذّر بدء اللعب التعاوني: لا يمكن استخدام منفذ UDP رقم %1 (الخطأ %2): غيّر قيمة Port في PhantomPact.ini على الجهازين" },  -- tip.relayerr.port_cant
        { "^تعذّر بدء اللعب التعاوني: couldn't find the host address (.+)$", "تعذّر بدء اللعب التعاوني: لم يُعثر على عنوان المضيف %1" },  -- tip.relayerr.no_host
        { "^تعذّر بدء اللعب التعاوني: this game's Steam has no (.+)$", "تعذّر بدء اللعب التعاوني: لا يحتوي Steam في هذه اللعبة على %1" },  -- tip.relayerr.steam_no_fn
        { "^تعذّر بدء اللعب التعاوني: Steam isn't loaded in this game %(steam_api64%.dll%)$", "تعذّر بدء اللعب التعاوني: لم يُحمَّل Steam في هذه اللعبة (steam_api64.dll)" },  -- tip.relayerr.steam_not_loaded
        { "^تعذّر بدء اللعب التعاوني: Steam isn't ready: is it running and logged in%?$", "تعذّر بدء اللعب التعاوني: لم يجهز Steam بعد: هل هو مفتوح وقد سجّلت الدخول إليه؟" },  -- tip.relayerr.steam_not_ready
        { "^your story caught up with the host's: (%d+) steps?%.$", "لحقت قصتك بقصة المضيف (الخطوات: %1)." },  -- tip.partner.story_caught
        -- more than two players (each player's own lines are below)
        { " Players: (%d) of (%d)%.", " اللاعبون: %1 من %2." },  -- f5.words.players
        { "^someone tried to join, but the party is full %((%d) players%)%.$", "حاول أحدهم الانضمام، لكن المجموعة ممتلئة (%1 لاعبين)." },  -- tip.conn.party_full
        { "^player (%d) is on Phantom Pact (.+) and you're on (.+): use the same version, or enemies won't stay in step%.$", "اللاعب %1 يستخدم Phantom Pact %2 وأنت تستخدم %3: يجب استخدام الإصدار نفسه، وإلا فلن يبقى الأعداء متزامنين." },  -- tip.conn.version_player
        -- PvP (F6). Players' names first, as the lines below them say.
        { "^Waiting for (.+) to be ready%.$", "بانتظار أن يستعد %1." },  -- f6.words.waiting_ready
        { "^(.+) needs Phantom Pact (.+) for PvP%.$", "يحتاج %1 إلى Phantom Pact %2 للعب PvP." },  -- f6.words.needs_version
        { "^(.+) is on Phantom Pact (.+): everyone needs (.+)%.$", "%1 يستخدم Phantom Pact %2: يحتاج الجميع إلى الإصدار %3." },  -- f6.words.other_version
        { "^(.+) hasn't beaten (.+) yet: that arena opens after the fight%.$", "%1 لم يهزم %2 بعد: تُفتح هذه الساحة بعد المعركة." },  -- f6.words.not_beaten
        { "^(.+) is on another map: for Here, everyone on (.+) %(F3 takes you to a partner%)%.$", "%1 في خريطة أخرى: لساحة «هنا» يلزم وجود الجميع في %2 (اضغط F3 للانتقال إلى شريك)." },  -- f6.words.other_map
        { "^everyone needs (.+) beaten in their own game for that arena%.$", "لهذه الساحة، يجب أن يهزم الجميع %1، كلٌّ في لعبته." },  -- tip.pvp.needs_beaten
        { "^Waiting to hear the host's match %(the host needs Phantom Pact (.+)%)%.$", "بانتظار معلومات نزال المضيف (يحتاج المضيف إلى Phantom Pact %1)." },  -- f6.words.waiting_host
        { "^Duel, best of three, ", "مبارزة، الفوز بجولتين من ثلاث، " },  -- tip.pvp.start.duel
        { "^Death, one life, ", "قتال حتى الموت، حياة واحدة، " },  -- tip.pvp.start.death
        { "no timer%. ", "بلا حد زمني. " },  -- tip.pvp.start.no_timer
        { "(%d+) s a round%. ", "%1 ثانية للجولة. " },  -- tip.pvp.start.timer
        { "Crimson team%. ", "الفريق القرمزي. " },  -- tip.pvp.start.crimson
        { "Azure team%. ", "الفريق اللازوردي. " },  -- tip.pvp.start.azure
        { "الفريق القرمزي%. To (.+)%.$", "الفريق القرمزي. إلى %1." },  -- tip.pvp.start.to
        { "الفريق اللازوردي%. To (.+)%.$", "الفريق اللازوردي. إلى %1." },  -- tip.pvp.start.to
        { "^back from the match: the match is over%.$", "عدت من النزال: انتهى النزال." },  -- tip.pvp.back.over
        { "^back from the match: you left%.$", "عدت من النزال: غادرت." },  -- tip.pvp.back.you_left
        { "^back from the match: you died%.$", "عدت من النزال: لقيت حتفك." },  -- tip.pvp.back.you_died
        { "^back from the match: a player was lost%.$", "عدت من النزال: انقطع اتصال أحد اللاعبين." },  -- tip.pvp.back.player_lost
        { "^back from the match: the host was lost%.$", "عدت من النزال: انقطع اتصال المضيف." },  -- tip.pvp.back.host_lost
        { "^back from the match: co%-op was turned off%.$", "عدت من النزال: أُوقف اللعب التعاوني." },  -- tip.pvp.back.coop_off
        { "^back from the match: the trip to the arena took too long%.$", "عدت من النزال: طال الانتقال إلى الساحة." },  -- tip.pvp.back.trip_long
        { "^back from the match: you couldn't get to the arena%.$", "عدت من النزال: تعذّر عليك الوصول إلى الساحة." },  -- tip.pvp.back.you_couldnt
        { "^back from the match: not everyone got to the arena in time%.$", "عدت من النزال: لم يصل الجميع إلى الساحة في الوقت المحدد." },  -- tip.pvp.back.late
        { "^back from the match: (.+) was lost%.$", "عدت من النزال: انقطع اتصال %1." },  -- tip.pvp.back.name_lost
        { "^back from the match: (.+) left%.$", "عدت من النزال: غادر %1." },  -- tip.pvp.back.name_left
        { "^back from the match: (.+) couldn't get to the arena%.$", "عدت من النزال: تعذّر على %1 الوصول إلى الساحة." },  -- tip.pvp.back.name_couldnt
        { "^back from the match: your world never finished its fight with (.+): that arena is closed for you%.$", "عدت من النزال: لم يكتمل القتال مع %1 في عالمك، فهذه الساحة مغلقة أمامك." },  -- tip.pvp.back.your_world
        { "^back from the match: (.+)'s world never finished that arena's boss fight%.$", "عدت من النزال: لم تكتمل معركة زعيم تلك الساحة في عالم %1." },  -- tip.pvp.back.their_world
        { "^back from the match: (.+)%.$", "عدت من النزال: %1." },  -- tip.pvp.back.other
        -- local co-op (F4): no Chinese. The checklist once for each pair of devices it can name.
        { "^keyboard is player 1, keyboard is player 2%. F4: screen and pads%. Player 2: Cross climbs and jumps, Circle uses, D%-pad down drinks%.$", "اللاعب 1: لوحة المفاتيح، واللاعب 2: لوحة المفاتيح. اضغط F4 لضبط الشاشة ووحدات التحكم. اللاعب 2: زر إكس للتسلق والقفز، وزر الدائرة للتفاعل، وزر الاتجاه السفلي للشرب." },  -- local.tip.checklist
        { "^keyboard is player 1, pad (%d) is player 2%. F4: screen and pads%. Player 2: Cross climbs and jumps, Circle uses, D%-pad down drinks%.$", "اللاعب 1: لوحة المفاتيح، واللاعب 2: وحدة التحكم %1. اضغط F4 لضبط الشاشة ووحدات التحكم. اللاعب 2: زر إكس للتسلق والقفز، وزر الدائرة للتفاعل، وزر الاتجاه السفلي للشرب." },  -- local.tip.checklist
        { "^pad (%d) is player 1, keyboard is player 2%. F4: screen and pads%. Player 2: Cross climbs and jumps, Circle uses, D%-pad down drinks%.$", "اللاعب 1: وحدة التحكم %1، واللاعب 2: لوحة المفاتيح. اضغط F4 لضبط الشاشة ووحدات التحكم. اللاعب 2: زر إكس للتسلق والقفز، وزر الدائرة للتفاعل، وزر الاتجاه السفلي للشرب." },  -- local.tip.checklist
        { "^pad (%d) is player 1, pad (%d) is player 2%. F4: screen and pads%. Player 2: Cross climbs and jumps, Circle uses, D%-pad down drinks%.$", "اللاعب 1: وحدة التحكم %1، واللاعب 2: وحدة التحكم %2. اضغط F4 لضبط الشاشة ووحدات التحكم. اللاعب 2: زر إكس للتسلق والقفز، وزر الدائرة للتفاعل، وزر الاتجاه السفلي للشرب." },  -- local.tip.checklist
        { "^player (%d) is on a new controller%.$", "انتقل اللاعب %1 إلى وحدة تحكم جديدة." },  -- local.tip.new_pad
        { "^player (%d)'s controller is disconnected%. Reconnect it, or hold a button on another%.$", "انقطع اتصال وحدة تحكم اللاعب %1. أعد توصيلها، أو اضغط مطوّلًا على زر في وحدة تحكم أخرى." },  -- local.tip.pad_lost
        { "^player (%d)'s controller is back%.$", "عادت وحدة تحكم اللاعب %1." },  -- local.tip.pad_back
        -- said of a player by name, a row for each: they start with the name, so they reach no other line
        { "^the host %(purple%) joined%. (%d) players now%.$", "انضم المضيف (بنفسجي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_joined
        { "^the host %(purple%) left%. (%d) players now%.$", "غادر المضيف (بنفسجي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_left
        { "^the host %(purple%) is down%.$", "سقط المضيف (بنفسجي)." },  -- tip.party.down
        { "^the host %(purple%) is back%.$", "عاد المضيف (بنفسجي)." },  -- tip.party.back
        { "^the host %(purple%) is watching a cutscene%.$", "يشاهد المضيف (بنفسجي) مشهدًا سينمائيًا." },  -- tip.party.cutscene
        { "^the host %(purple%) is on another map%.$", "المضيف (بنفسجي) في خريطة أخرى." },  -- tip.party.other_map
        { "^the host %(purple%) is (%d+) m away%.$", "المضيف (بنفسجي) على بُعد %1 متر." },  -- tip.party.far
        { "^the host %(purple%) rested at a bell: you'll join them%.$", "استراح المضيف (بنفسجي) عند جرس: ستنتقل إليه." },  -- tip.party.rest_join
        { "^the host %(purple%) rested at a bell: you're rested, and so is the boss%.$", "استراح المضيف (بنفسجي) عند جرس، واستعدت عافيتك، وكذلك الزعيم." },  -- tip.party.rest_boss
        { "^the host %(purple%) turned co%-op sync off%.$", "أوقف المضيف (بنفسجي) مزامنة اللعب التعاوني." },  -- tip.party.sync_off
        { " You're the host %(purple%)%.$", " أنت المضيف (بنفسجي)." },  -- f5.words.youre
        { "^player 2 %(green%) joined%. (%d) players now%.$", "انضم اللاعب 2 (أخضر). عدد اللاعبين الآن: %1." },  -- tip.conn.party_joined
        { "^player 2 %(green%) left%. (%d) players now%.$", "غادر اللاعب 2 (أخضر). عدد اللاعبين الآن: %1." },  -- tip.conn.party_left
        { "^player 2 %(green%) is down%.$", "سقط اللاعب 2 (أخضر)." },  -- tip.party.down
        { "^player 2 %(green%) is back%.$", "عاد اللاعب 2 (أخضر)." },  -- tip.party.back
        { "^player 2 %(green%) is watching a cutscene%.$", "يشاهد اللاعب 2 (أخضر) مشهدًا سينمائيًا." },  -- tip.party.cutscene
        { "^player 2 %(green%) is on another map%.$", "اللاعب 2 (أخضر) في خريطة أخرى." },  -- tip.party.other_map
        { "^player 2 %(green%) is (%d+) m away%.$", "اللاعب 2 (أخضر) على بُعد %1 متر." },  -- tip.party.far
        { "^player 2 %(green%) rested at a bell: you'll join them%.$", "استراح اللاعب 2 (أخضر) عند جرس: ستنتقل إليه." },  -- tip.party.rest_join
        { "^player 2 %(green%) rested at a bell: you're rested, and so is the boss%.$", "استراح اللاعب 2 (أخضر) عند جرس، واستعدت عافيتك، وكذلك الزعيم." },  -- tip.party.rest_boss
        { "^player 2 %(green%) turned co%-op sync off%.$", "أوقف اللاعب 2 (أخضر) مزامنة اللعب التعاوني." },  -- tip.party.sync_off
        { " You're player 2 %(green%)%.$", " أنت اللاعب 2 (أخضر)." },  -- f5.words.youre
        { "^player 3 %(gold%) joined%. (%d) players now%.$", "انضم اللاعب 3 (ذهبي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_joined
        { "^player 3 %(gold%) left%. (%d) players now%.$", "غادر اللاعب 3 (ذهبي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_left
        { "^player 3 %(gold%) is down%.$", "سقط اللاعب 3 (ذهبي)." },  -- tip.party.down
        { "^player 3 %(gold%) is back%.$", "عاد اللاعب 3 (ذهبي)." },  -- tip.party.back
        { "^player 3 %(gold%) is watching a cutscene%.$", "يشاهد اللاعب 3 (ذهبي) مشهدًا سينمائيًا." },  -- tip.party.cutscene
        { "^player 3 %(gold%) is on another map%.$", "اللاعب 3 (ذهبي) في خريطة أخرى." },  -- tip.party.other_map
        { "^player 3 %(gold%) is (%d+) m away%.$", "اللاعب 3 (ذهبي) على بُعد %1 متر." },  -- tip.party.far
        { "^player 3 %(gold%) rested at a bell: you'll join them%.$", "استراح اللاعب 3 (ذهبي) عند جرس: ستنتقل إليه." },  -- tip.party.rest_join
        { "^player 3 %(gold%) rested at a bell: you're rested, and so is the boss%.$", "استراح اللاعب 3 (ذهبي) عند جرس، واستعدت عافيتك، وكذلك الزعيم." },  -- tip.party.rest_boss
        { "^player 3 %(gold%) turned co%-op sync off%.$", "أوقف اللاعب 3 (ذهبي) مزامنة اللعب التعاوني." },  -- tip.party.sync_off
        { " You're player 3 %(gold%)%.$", " أنت اللاعب 3 (ذهبي)." },  -- f5.words.youre
        { "^player 4 %(blue%) joined%. (%d) players now%.$", "انضم اللاعب 4 (أزرق). عدد اللاعبين الآن: %1." },  -- tip.conn.party_joined
        { "^player 4 %(blue%) left%. (%d) players now%.$", "غادر اللاعب 4 (أزرق). عدد اللاعبين الآن: %1." },  -- tip.conn.party_left
        { "^player 4 %(blue%) is down%.$", "سقط اللاعب 4 (أزرق)." },  -- tip.party.down
        { "^player 4 %(blue%) is back%.$", "عاد اللاعب 4 (أزرق)." },  -- tip.party.back
        { "^player 4 %(blue%) is watching a cutscene%.$", "يشاهد اللاعب 4 (أزرق) مشهدًا سينمائيًا." },  -- tip.party.cutscene
        { "^player 4 %(blue%) is on another map%.$", "اللاعب 4 (أزرق) في خريطة أخرى." },  -- tip.party.other_map
        { "^player 4 %(blue%) is (%d+) m away%.$", "اللاعب 4 (أزرق) على بُعد %1 متر." },  -- tip.party.far
        { "^player 4 %(blue%) rested at a bell: you'll join them%.$", "استراح اللاعب 4 (أزرق) عند جرس: ستنتقل إليه." },  -- tip.party.rest_join
        { "^player 4 %(blue%) rested at a bell: you're rested, and so is the boss%.$", "استراح اللاعب 4 (أزرق) عند جرس، واستعدت عافيتك، وكذلك الزعيم." },  -- tip.party.rest_boss
        { "^player 4 %(blue%) turned co%-op sync off%.$", "أوقف اللاعب 4 (أزرق) مزامنة اللعب التعاوني." },  -- tip.party.sync_off
        { " You're player 4 %(blue%)%.$", " أنت اللاعب 4 (أزرق)." },  -- f5.words.youre
        { "^player 5 %(orange%) joined%. (%d) players now%.$", "انضم اللاعب 5 (برتقالي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_joined
        { "^player 5 %(orange%) left%. (%d) players now%.$", "غادر اللاعب 5 (برتقالي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_left
        { "^player 5 %(orange%) is down%.$", "سقط اللاعب 5 (برتقالي)." },  -- tip.party.down
        { "^player 5 %(orange%) is back%.$", "عاد اللاعب 5 (برتقالي)." },  -- tip.party.back
        { "^player 5 %(orange%) is watching a cutscene%.$", "يشاهد اللاعب 5 (برتقالي) مشهدًا سينمائيًا." },  -- tip.party.cutscene
        { "^player 5 %(orange%) is on another map%.$", "اللاعب 5 (برتقالي) في خريطة أخرى." },  -- tip.party.other_map
        { "^player 5 %(orange%) is (%d+) m away%.$", "اللاعب 5 (برتقالي) على بُعد %1 متر." },  -- tip.party.far
        { "^player 5 %(orange%) rested at a bell: you'll join them%.$", "استراح اللاعب 5 (برتقالي) عند جرس: ستنتقل إليه." },  -- tip.party.rest_join
        { "^player 5 %(orange%) rested at a bell: you're rested, and so is the boss%.$", "استراح اللاعب 5 (برتقالي) عند جرس، واستعدت عافيتك، وكذلك الزعيم." },  -- tip.party.rest_boss
        { "^player 5 %(orange%) turned co%-op sync off%.$", "أوقف اللاعب 5 (برتقالي) مزامنة اللعب التعاوني." },  -- tip.party.sync_off
        { " You're player 5 %(orange%)%.$", " أنت اللاعب 5 (برتقالي)." },  -- f5.words.youre
        { "^player 6 %(pink%) joined%. (%d) players now%.$", "انضم اللاعب 6 (وردي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_joined
        { "^player 6 %(pink%) left%. (%d) players now%.$", "غادر اللاعب 6 (وردي). عدد اللاعبين الآن: %1." },  -- tip.conn.party_left
        { "^player 6 %(pink%) is down%.$", "سقط اللاعب 6 (وردي)." },  -- tip.party.down
        { "^player 6 %(pink%) is back%.$", "عاد اللاعب 6 (وردي)." },  -- tip.party.back
        { "^player 6 %(pink%) is watching a cutscene%.$", "يشاهد اللاعب 6 (وردي) مشهدًا سينمائيًا." },  -- tip.party.cutscene
        { "^player 6 %(pink%) is on another map%.$", "اللاعب 6 (وردي) في خريطة أخرى." },  -- tip.party.other_map
        { "^player 6 %(pink%) is (%d+) m away%.$", "اللاعب 6 (وردي) على بُعد %1 متر." },  -- tip.party.far
        { "^player 6 %(pink%) rested at a bell: you'll join them%.$", "استراح اللاعب 6 (وردي) عند جرس: ستنتقل إليه." },  -- tip.party.rest_join
        { "^player 6 %(pink%) rested at a bell: you're rested, and so is the boss%.$", "استراح اللاعب 6 (وردي) عند جرس، واستعدت عافيتك، وكذلك الزعيم." },  -- tip.party.rest_boss
        { "^player 6 %(pink%) turned co%-op sync off%.$", "أوقف اللاعب 6 (وردي) مزامنة اللعب التعاوني." },  -- tip.party.sync_off
        { " You're player 6 %(pink%)%.$", " أنت اللاعب 6 (وردي)." },  -- f5.words.youre
        -- last, names anywhere in a line, after the lines' own rows: the arenas (longer first), Here, bosses, players
        { "إلى Here%.", "إلى «هنا»." },  -- term.arena.here
        { "the Gold%-Masked One", "The Gold-Masked One" },  -- term.boss.goldmask
        { "the host %(purple%)", "المضيف (بنفسجي)" },  -- term.player1
        { "player 2 %(green%)", "اللاعب 2 (أخضر)" },  -- term.player2
        { "player 3 %(gold%)", "اللاعب 3 (ذهبي)" },  -- term.player3
        { "player 4 %(blue%)", "اللاعب 4 (أزرق)" },  -- term.player4
        { "player 5 %(orange%)", "اللاعب 5 (برتقالي)" },  -- term.player5
        { "player 6 %(pink%)", "اللاعب 6 (وردي)" },  -- term.player6
    },
}
