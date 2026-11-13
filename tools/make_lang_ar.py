"""Builds mod/PBZCoop/Scripts/lang_ar.lua, the Arabic for lang.lua: whole lines (LINES) and pieces of lines (PARTS, Lua
patterns that say() applies in order), on the same English as lang.lua's Chinese rows.

The Arabic comes from art/arabic.tsv (columns id, english, arabic, notes), the file the Arabic pictures come from too
(art/make_arabic_art.py). The patterns are here, by the tsv's ids, in the order of the Chinese ones. In the tsv's
Arabic, %1, %2... are the English's %s and %d in their order: each goes where its capture is, or a player's name where
a row is made for each name. Correct a line in the tsv, run this again, then the sims (luasim.py four checks every row,
and a whole line's English against the scripts), and python -I art/make_arabic_art.py when the word is on a picture too:

    python -I tools/make_lang_ar.py [arabic.tsv]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TSV = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "art", "arabic.tsv")
OUT = os.path.join(HERE, "..", "mod", "PBZCoop", "Scripts", "lang_ar.lua")

PLAYERS = ["term.player%d" % n for n in range(1, 7)]

# Whole lines, the English as the code builds it: lang.lua's Chinese ones in their order, then the ones with no Chinese.
# (The tip's head, YOU and a foe's PLAYER are the code's own pieces: it says each on its own.)
LINES = [
    ("the panel", ["f5.words.not_connected", "f5.words.starting", "f5.words.waiting", "f5.words.looking_steam",
                   "f5.words.paste_first", "f5.words.pw_first", "f5.words.pw_set", "f5.words.pw_removed",
                   "f5.words.ini_no_address", "f5.words.ini_bad_char", "tip.conn.build", "tip.conn.no_dll"]),
    ("PvP (F6)", ["f6.words.restoring", "tip.pvp.too_late", "tip.pvp.talismans"]),
    ("the partner", ["tip.partner.down", "tip.partner.back", "tip.partner.cutscene", "tip.partner.rest_join",
                     "tip.partner.rest_boss", "f5more.tip.pvpve_partner", "f5more.tip.pvpve_all",
                     "tip.conn.disconnected", "tip.partner.sync_off", "f5more.tip.pvpve_party", "f5more.tip.local_next",
                     "f5more.tip.players_host", "f5more.tip.host_setting", "f5more.tip.players_next",
                     "local.tip.multiplayer_next", "tip.f3.tp_off", "tip.f3.too_late", "tip.f3.no_partner", "tip.f3.not_now",
                     "tip.f3.in_prologue", "f5more.tip.skip_how", "f5more.tip.past_prologue", "tip.f3.partner_prologue",
                     "tip.f3.cant_join", "tip.f3.position", "tip.f3.map_unknown", "tip.f3.wouldnt_go"]),
    ("revive", ["tip.boss.hold", "tip.boss.watching", "tip.boss.wall_join", "tip.boss.taking_long", "tip.boss.f3_join",
                "tip.boss.no_ground", "tip.conn.clock", "revive.tip.up", "revive.tip.down", "revive.tip.partner_down",
                "revive.tip.partner_up"]),
    ("PvP (F6)", ["f6.words.offline_short", "f6.words.offline", "f6.words.host_starts", "f6.words.nobody",
                  "f6.words.both_teams", "f6.words.three_a_side", "f6.words.all_ready", "f6.words.you_ready",
                  "f6.words.set_loadout", "f6.words.pick", "f6.words.in_match", "tip.pvp.no_arena", "tip.pvp.press_leave",
                  "tip.pvp.get_closer", "tip.pvp.cut_short", "tip.pvp.host_sets", "tip.pvp.two_players",
                  "tip.pvp.loadout_next"]),
    ("the connection", ["tip.conn.nobody_joined", "tip.conn.secret", "tip.conn.steam_relay"]),
    ("no Chinese: the tip's head (status.lua says it on its own), the partner, local co-op (F4)",
     ["tip.prefix", "tip.conn.connected_signed", "tip.conn.connected", "tip.partner.quest_step", "local.tip.close_menu",
      "local.tip.wall", "local.tip.p2_joined", "local.tip.gourd_empty", "local.tip.mon_lr", "local.tip.mon_tb",
      "local.tip.mon_single", "local.tip.mon_mode"]),
    ("the match screen (arenaui.lua): the countdown's words, a foe's name before their slot, YOU before the score",
     ["match.count.one", "match.count.two", "match.count.three", "match.count.fight", "match.timeup",
      ("match.foe.name", "before number"), ("match.foe.score", "in score")]),
]

# Pieces of lines, in this order: a row and its Lua pattern, the Arabic's %1, %2... going where its captures are, in their
# order. Three groups are made from the lists below: "errors" (the relay's errors after each of the two heads, the rows
# that end in (.*)$), "names" (a row for each player) and "anywhere" (names anywhere in a line, last).
PARTS = [
    ("the panel's line: Connected to, then each piece with its own leading space", [
        ("f5.words.connected", "^Connected to (%S+)%."),
        ("f5.words.ping", " Ping (%d+) ms%."),
        ("f5.words.route_direct", " Route: direct%."),
        ("f5.words.route_relay", " Route: relay%."),
        ("f5.words.couldnt_start", "^Couldn't start: (.*)$"),
        ("tip.conn.no_write", "^Couldn't start the relay: net_start%.txt can't be written in (.+)$"),
        ("f5.words.looking_for", "^Looking for (.+)%.%.%.$"),
        ("f5.words.address_set", "^Host address set to (.+)%.$"),
    ]),
    ("the partner and the connection", [
        ("tip.partner.other_map", "^your partner is on another map%."),
        ("tip.partner.far", "^your partner is (%d+) m away%."),
        ("tip.partner.f3_there", " F3 takes you there%.$"),
        ("tip.conn.connected_ping_signed", "^partner connected %(ping (%d+) ms%), signed%.$"),
        ("tip.conn.connected_ping", "^partner connected %(ping (%d+) ms%)%.$"),
        ("tip.partner.bag", "^your bag now has what your partner's has %((%d+) new%)%.$"),
        ("tip.conn.couldnt_start", "^co%-op couldn't start: (.*)$"),
        ("tip.conn.steam_couldnt", "^Steam couldn't connect: (.+)%. See Connection problems in the install guide%.$"),
        ("tip.conn.settings_differ", "^settings differ from your partner's: (.*)$"),
        ("tip.conn.version_cant", "^your partner's Phantom Pact %((.+)%) can't connect to (.+): both PCs need the same "
                                  "version%.$"),
        # (The relay's own words for their version in it: left English, they showed reversed in a right-to-left line.)
        ("term.version.older", "1%.4%.1%-or%-older"),
        ("term.version.other", "other%-protocol"),
        ("tip.conn.version_diff", "^your partner is on Phantom Pact (.+) and you're on (.+): use the same version, or "
                                  "enemies won't stay in step%.$"),
        ("tip.conn.high_ping", "^high ping %((%d+) ms%)%."),
        ("tip.conn.tailscale_ping", " On Tailscale, run \"tailscale ping\": via DERP means relayed%.$"),
        ("tip.conn.no_answer", "^no answer from the host %((.+)%)%. Check HostAddress and Port, that they're in the game "
                               "on Role = Host, and the same Secret and Phantom Pact version on both PCs%.$"),
        ("tip.conn.no_friend", "^no friend hosting found%..*$"),
    ]),
    ("the relay's own errors, after the panel's head or a tip's (the two rows above that end in (.*)$)", "errors"),
    ("", [
        ("tip.partner.story_caught", "^your story caught up with the host's: (%d+) steps?%.$"),
    ]),
    ("more than two players (each player's own lines are below)", [
        ("f5.words.players", " Players: (%d) of (%d)%."),
        ("tip.conn.party_full", "^someone tried to join, but the party is full %((%d) players%)%.$"),
        ("tip.conn.version_player", "^player (%d) is on Phantom Pact (.+) and you're on (.+): use the same version, or "
                                    "enemies won't stay in step%.$"),
    ]),
    ("PvP (F6). Players' names first, as the lines below them say.", [
        ("f6.words.waiting_ready", "^Waiting for (.+) to be ready%.$"),
        ("f6.words.needs_version", "^(.+) needs Phantom Pact (.+) for PvP%.$"),
        ("f6.words.other_version", "^(.+) is on Phantom Pact (.+): everyone needs (.+)%.$"),
        ("f6.words.not_beaten", "^(.+) hasn't beaten (.+) yet: that arena opens after the fight%.$"),
        ("f6.words.other_map", "^(.+) is on another map: for Here, everyone on (.+) %(F3 takes you to a partner%)%.$"),
        ("tip.pvp.needs_beaten", "^everyone needs (.+) beaten in their own game for that arena%.$"),
        ("f6.words.waiting_host", "^Waiting to hear the host's match %(the host needs Phantom Pact (.+)%)%.$"),
        ("tip.pvp.start.duel", "^Duel, best of three, "),
        ("tip.pvp.start.death", "^Death, one life, "),
        ("tip.pvp.start.no_timer", "no timer%. "),
        ("tip.pvp.start.timer", "(%d+) s a round%. "),
        ("tip.pvp.start.crimson", "Crimson team%. "),
        ("tip.pvp.start.azure", "Azure team%. "),
        ("tip.pvp.start.to", "To (.+)%.$"),
        ("tip.pvp.back.over", "^back from the match: the match is over%.$"),
        ("tip.pvp.back.you_left", "^back from the match: you left%.$"),
        ("tip.pvp.back.you_died", "^back from the match: you died%.$"),
        ("tip.pvp.back.player_lost", "^back from the match: a player was lost%.$"),
        ("tip.pvp.back.host_lost", "^back from the match: the host was lost%.$"),
        ("tip.pvp.back.coop_off", "^back from the match: co%-op was turned off%.$"),
        ("tip.pvp.back.trip_long", "^back from the match: the trip to the arena took too long%.$"),
        ("tip.pvp.back.you_couldnt", "^back from the match: you couldn't get to the arena%.$"),
        ("tip.pvp.back.late", "^back from the match: not everyone got to the arena in time%.$"),
        ("tip.pvp.back.name_lost", "^back from the match: (.+) was lost%.$"),
        ("tip.pvp.back.name_left", "^back from the match: (.+) left%.$"),
        ("tip.pvp.back.name_couldnt", "^back from the match: (.+) couldn't get to the arena%.$"),
        ("tip.pvp.back.your_world", "^back from the match: your world never finished its fight with (.+): that arena is "
                                    "closed for you%.$"),
        ("tip.pvp.back.their_world", "^back from the match: (.+)'s world never finished that arena's boss fight%.$"),
        ("tip.pvp.back.other", "^back from the match: (.+)%.$"),
    ]),
    ("local co-op (F4): no Chinese. The checklist once for each pair of devices it can name.", [
        ("local.tip.checklist", "^(.+) is player 1, (.+) is player 2%. F4: screen and pads%. Player 2: Cross climbs and "
                                "jumps, Circle uses, D%-pad down drinks%.$"),
        ("local.tip.new_pad", "^player (%d) is on a new controller%.$"),
        ("local.tip.pad_lost", "^player (%d)'s controller is disconnected%. Reconnect it, or hold a button on another%.$"),
        ("local.tip.pad_back", "^player (%d)'s controller is back%.$"),
    ]),
    ("said of a player by name, a row for each: they start with the name, so they reach no other line", "names"),
    ("last, names anywhere in a line, after the lines' own rows: the arenas (longer first), Here, bosses, players",
     "anywhere"),
]

# The relay's errors (native/relay.hpp, native/steam.cpp), as English patterns: each gets a row after each head.
HEADS = ["f5.words.couldnt_start", "tip.conn.couldnt_start"]
ERRORS = [
    ("tip.relayerr.random", "no system random numbers for the Secret"),
    ("tip.relayerr.winsock", "Winsock didn't start"),
    ("tip.relayerr.socket", "couldn't open a UDP socket"),
    ("tip.relayerr.port_in_use", "UDP port (%d+) is in use on this PC %(error (%d+)%): set another Port in "
                                 "PhantomPact%.ini on both PCs"),
    ("tip.relayerr.port_cant", "UDP port (%d+) can't be used %(error (%d+)%): set another Port in PhantomPact%.ini on "
                               "both PCs"),
    ("tip.relayerr.no_host", "couldn't find the host address (.+)"),
    ("tip.relayerr.steam_no_fn", "this game's Steam has no (.+)"),
    ("tip.relayerr.steam_not_loaded", "Steam isn't loaded in this game %(steam_api64%.dll%)"),
    ("tip.relayerr.steam_not_ready", "Steam isn't ready: is it running and logged in%?"),
]

# Said of a player by name (their name is the Arabic's %1): the English after the name, as a pattern.
NAMED = [
    ("tip.conn.party_joined", " joined%. (%d) players now%.$"),
    ("tip.conn.party_left", " left%. (%d) players now%.$"),
    ("tip.party.down", " is down%.$"),
    ("tip.party.back", " is back%.$"),
    ("tip.party.cutscene", " is watching a cutscene%.$"),
    ("tip.party.other_map", " is on another map%.$"),
    ("tip.party.far", " is (%d+) m away%.$"),
    ("tip.party.rest_join", " rested at a bell: you'll join them%.$"),
    ("tip.party.rest_boss", " rested at a bell: you're rested, and so is the boss%.$"),
    ("tip.party.sync_off", " turned co%-op sync off%.$"),
]
YOURE = "f5.words.youre"            # the panel's " You're %s.": a row for each name too

# Names anywhere, in this order. HERE: the arena's English in the start tip's To %s. is put right (lang.lua's 前往Here。).
ANYWHERE = ["term.arena.goldmask", "term.arena.huaqianxiao", "term.arena.muxiaokui", "term.arena.yucong", "HERE",
            "term.boss.goldmask", "term.boss.huaqianxiao", "term.boss.muxiaokui", "term.boss.yucong"] + PLAYERS
TO, HERE_NAME = "tip.pvp.start.to", "term.arena.here"
TEAMS = ["tip.pvp.start.crimson", "tip.pvp.start.azure"]
CHECKLIST, KEYBOARD, PAD = "local.tip.checklist", "local.word.keyboard", "local.word.pad"

SLOT = re.compile(r"%(\d)")
problems = []


def read(path):
    rows = {}
    with open(path, encoding="utf-8-sig", newline="") as fh:
        lines = fh.read().split("\n")
    head = lines[0].rstrip("\r").split("\t")
    for line in lines[1:]:
        line = line.rstrip("\r")
        if line:
            row = dict(zip(head, line.split("\t")))
            rows[row["id"]] = row
    return rows


T = read(TSV)


def get(rid):
    row = T.get(rid)
    if row is None or not row.get("arabic"):
        problems.append("%s: not in %s, or no Arabic" % (rid, TSV))
        return {"english": "", "arabic": ""}
    return row


def esc(text):
    """Literal text in a Lua pattern."""
    return re.sub(r"([\^$()%.\[\]*+\-?])", r"%\1", text)


def rep(text):
    """Literal text in a gsub replacement."""
    return text.replace("%", "%%")


def captures(pattern):
    n, i = 0, 0
    while i < len(pattern):
        if pattern[i] == "%":
            i += 1
        elif pattern[i] == "(":
            n += 1
        i += 1
    return n


def fill(rid, values):
    """The row's Arabic with its %1, %2... as values[0], values[1]..., the rest kept as it is (as replacement text)."""
    english, arabic = get(rid)["english"], get(rid)["arabic"]
    if not arabic:
        return ""
    holes = len(re.findall(r"%[sd]", english))
    if sorted(int(n) for n in SLOT.findall(arabic)) != list(range(1, holes + 1)):
        problems.append("%s: its Arabic needs %%1, %%2... once each for the English's %d %%s and %%d" % (rid, holes))
        return ""
    if len(values) != holes:
        problems.append("%s: %d values for its %d places" % (rid, len(values), holes))
        return ""
    out, at = [], 0
    for m in SLOT.finditer(arabic):
        out.append(rep(arabic[at:m.start()]))
        out.append(values[int(m.group(1)) - 1])
        at = m.end()
    out.append(rep(arabic[at:]))
    return "".join(out)


def spaces(rid):
    """A piece keeps the English's leading and trailing space, or it runs into its neighbours."""
    english, arabic = get(rid)["english"], get(rid)["arabic"]
    if english[:1].isspace() != arabic[:1].isspace() or english[-1:].isspace() != arabic[-1:].isspace():
        problems.append("%s: its Arabic should start and end with a space where the English does" % rid)


def part(rid, pattern, values=None):
    n = captures(pattern)
    values = ["%%%d" % (k + 1) for k in range(n)] if values is None else values
    used = set(int(m) for v in values for m in re.findall(r"(?<!%)%(\d)", v))
    if used != set(range(1, n + 1)):
        problems.append("%s: %s has %d captures, the Arabic uses %s" % (rid, pattern, n, sorted(used)))
    spaces(rid)
    return (pattern, fill(rid, values), rid)


def lines():
    groups = []
    for title, ids in LINES:
        rows = []
        for item in ids:
            rid, how = item if isinstance(item, tuple) else (item, None)
            english, arabic = get(rid)["english"], get(rid)["arabic"]
            if how == "before number":       # 'PLAYER %d': the code says say("PLAYER ") .. slot
                if not (english.endswith("%d") and arabic.endswith("%d")):
                    problems.append("%s: should end with %%d in both" % rid)
                english, arabic = english[:-2], arabic[:-2]
            elif how == "in score":          # '  ·  YOU %d – %d': the code says say("YOU") and puts the rest around it
                frame = re.compile(r"  · {2}(.+) %d – %d")
                en, ar = frame.fullmatch(english), frame.fullmatch(arabic)
                if not (en and ar):
                    problems.append("%s: should be '  ·  <word> %%d – %%d' in both" % rid)
                    continue
                english, arabic = en.group(1), ar.group(1)
            elif re.search(r"%[sd]", english) or SLOT.search(arabic):
                problems.append("%s: a whole line can't have a %%s, %%d or %%1" % rid)
            rows.append((english, arabic, rid))
        groups.append((title, rows))
    return groups


def parts():
    groups = []
    for title, spec in PARTS:
        rows = []
        if spec == "errors":
            for head in HEADS:
                arabic = get(head)["arabic"]
                if arabic.count("%1") != 1:
                    problems.append("%s: its Arabic needs its %%1 once" % head)
                    continue
                before, after = arabic.split("%1")
                for rid, pattern in ERRORS:
                    n = captures(pattern)
                    rows.append(("^" + esc(before) + pattern + esc(after) + "$",
                                 rep(before) + fill(rid, ["%%%d" % (k + 1) for k in range(n)]) + rep(after), rid))
        elif spec == "names":
            for who in PLAYERS:
                name, arabic = get(who)["english"], rep(get(who)["arabic"])
                for rid, after in NAMED:
                    n = captures(after)
                    rows.append(part(rid, "^" + esc(name) + after, [arabic] + ["%%%d" % (k + 1) for k in range(n)]))
                rows.append(part(YOURE, " You're " + esc(name) + "%.$", [arabic]))
        elif spec == "anywhere":
            for rid in ANYWHERE:
                if rid == "HERE":
                    # The start tip's To %s. with Here in it, as the row above made it: Here put in its Arabic.
                    english = get(TO)["arabic"].replace("%1", get(HERE_NAME)["english"])
                    rows.append((esc(english), fill(TO, [rep(get(HERE_NAME)["arabic"])]), HERE_NAME))
                elif get(rid)["arabic"] != get(rid)["english"]:
                    # (A name kept as it is needs no row: the game's own names stay English, as the game shows them
                    # and it has no Arabic. The user, 11-10.)
                    rows.append((esc(get(rid)["english"]), rep(get(rid)["arabic"]), rid))
            names = [get(rid)["english"] for rid in ANYWHERE if rid != "HERE"]
            for i, a in enumerate(names):
                for b in names[i + 1:]:
                    if a in b:
                        problems.append("names anywhere: %s comes before %s, which has it in it" % (a, b))
        else:
            for item in spec:
                if item[0] == TO:
                    # The arena's To %s. only after a team's piece, as arena.lua always says it: on its own it also
                    # reached any line ending in "To <something>.", a Steam friend's name in it.
                    for team in TEAMS:
                        team_ar = get(team)["arabic"]
                        rows.append((esc(team_ar) + item[1], rep(team_ar) + fill(TO, ["%1"]), TO))
                elif item[0] == CHECKLIST:
                    rows += checklist(item[1])
                else:
                    rows.append(part(*item))
        groups.append((title, rows))
    return groups


def checklist(pattern):
    """The local co-op checklist once for each pair of devices localcoop.lua can name ("keyboard", "pad N"), each put
    in as its Arabic: rows of their own for the two words also reached a Steam friend's name with "keyboard" in it."""
    ahead, middle, rest = pattern.split("(.+)")
    pad = get(PAD)["arabic"]
    if pad.count("%d") != 1:
        problems.append("%s: its Arabic needs the %%d once" % PAD)
        return []
    before, after = pad.split("%d")
    keyboard = (get(KEYBOARD)["english"], lambda k: rep(get(KEYBOARD)["arabic"]), 0)
    pad_n = ("pad (%d)", lambda k: rep(before) + "%%%d" % k + rep(after), 1)
    rows = []
    for one in (keyboard, pad_n):
        for two in (keyboard, pad_n):
            english = ahead + one[0] + middle + two[0] + rest
            row = (english, fill(CHECKLIST, [one[1](1), two[1](one[2] + 1)]), CHECKLIST)
            if captures(english) != one[2] + two[2]:
                problems.append("%s: %s has %d captures" % (CHECKLIST, english, captures(english)))
            rows.append(row)
    return rows


def lua(s):
    if "\n" in s or "\r" in s:
        problems.append("a line break in %r" % s)
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    line_groups, part_groups = lines(), parts()
    seen = set()
    for _, rows in line_groups:
        for english, _, rid in rows:
            if english in seen:
                problems.append("%s: its English is a key twice" % rid)
            seen.add(english)
    seen = set()
    for _, rows in part_groups:
        for pattern, _, rid in rows:
            if pattern in seen:
                problems.append("%s: its pattern is there twice" % rid)
            seen.add(pattern)
    if problems:
        print("lang_ar.lua not written:")
        for p in dict.fromkeys(problems):
            print("  " + p)
        return 1
    out = ["-- The online mode's words in Arabic, for lang.lua: the same English lines (LINES) and pieces of lines (PARTS,",
           "-- Lua patterns, applied in order) as its Chinese, with the Arabic put where the English's names and numbers go.",
           "-- Made by tools/make_lang_ar.py from art/arabic.tsv, which the Arabic pictures come from too: don't edit this,",
           "-- correct the tsv and run it again. Each row says its tsv id. The mod's author checks every line.",
           "return {", "    LINES = {"]
    n_lines = n_parts = 0
    for title, rows in line_groups:
        out.append("        -- " + title)
        for english, arabic, rid in rows:
            out.append("        [%s] = %s,  -- %s" % (lua(english), lua(arabic), rid))
            n_lines += 1
    out += ["    },", "    PARTS = {"]
    for title, rows in part_groups:
        if title:
            out.append("        -- " + title)
        for pattern, replacement, rid in rows:
            out.append("        { %s, %s },  -- %s" % (lua(pattern), lua(replacement), rid))
            n_parts += 1
    out += ["    },", "}"]
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out) + "\n")
    print("wrote %s: %d lines, %d parts" % (os.path.normpath(OUT), n_lines, n_parts))
    return 0


sys.exit(main())
