"""Builds the Arabic pictures (ar_*) of the online panel (F5), the PvP page (F6) and the match screens, and the online
panel's language button for Arabic (online_lang_ar). Each is its English twin's own ground (the background, frame and
art, drawn by the same code: make_local_panel.py, make_online_panel.py, make_pvp_art.py) with the words in Arabic:
right-aligned where the English is left-aligned, centred where it's centred, made smaller to fit their room. Windows
draws the Arabic (winrender.ps1: WPF joins the letters and lays them right to left; Pillow can't here).
The words come from art/arabic.tsv (columns id, english, arabic, notes), matched by the English: a picture with a word
that has no Arabic yet is skipped and listed, never guessed. A name the game writes in English stays English there
(the user's call: the game has no Arabic) and is set as the English pictures set it. Writes only ar_*.png and
online_lang_ar.png.
Needs Pillow and Windows:
    python -I art/make_arabic_art.py [table.tsv] [ar_name ...]     (art/arabic.tsv if not given; names: just those)
A word that is also a line on screen is in mod/PBZCoop/Scripts/lang_ar.lua too: run tools/make_lang_ar.py as well."""
import base64
import io
import json
import math
import os
import random
import re
import subprocess
import sys
from statistics import NormalDist

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)            # (python -I leaves the script's own folder off the path)

from PIL import Image, ImageChops, ImageDraw, ImageFilter

import make_local_panel as lp
import make_online_panel as op
import make_pvp_art as pv

K = lp.K
ARABIC = re.compile(r"[\u0600-\u06ff\u0750-\u077f\u08a0-\u08ff\ufb50-\ufdff\ufe70-\ufefc]")
NATIVE = "العربية"                 # the language button says "Arabic" in Arabic


# ------------------------------------------------------------------ the fonts

class Face:
    """An Arabic font as Windows has it (file: the one it must find). Arabic set at the English words' size reads
    smaller than they do, so it's set `scale` times bigger, and never under `smallest` pixels, where its dots run
    together. lead: a line's height, against its size. space: what goes between words (Sakkal Majalla's own space is
    so narrow that two words ending and starting with a letter that doesn't join, as in "فاز فريقك", read as one)."""

    def __init__(self, family, bold, file, scale, smallest, lead, space=" "):
        self.family, self.bold, self.file = family, bold, file
        self.scale, self.smallest, self.lead, self.space = scale, smallest, lead, space


THIN = "\u2009"         # a fifth of the size: the same gap, against the letters, as the other faces' own spaces
TITLE = Face("Arabic Typesetting", False, "arabtype.ttf", 1.75, 20, 1.2)    # the pages' titles: classical naskh
LABEL = Face("Sakkal Majalla", True, "majallab.ttf", 1.4, 13, 1.15, THIN)   # labels, buttons, names
PLAIN = Face("Sakkal Majalla", False, "majalla.ttf", 1.4, 13, 1.15, THIN)   # the language button, plain as its twins
BODY = Face("Segoe UI", False, "segoeui.ttf", 1.2, 10, 1.4)                 # small print and help
# The banners' words: a bold naskh on the brush smear, as the Chinese ones are a bold plain face on it (a calligraphic
# face, Aldhabi, is slower to read in a fight).
BANNER = Face("Sakkal Majalla", True, "majallab.ttf", 1.9, 30, 1.2, THIN)


class Windows:
    """winrender.ps1, started once, measures and draws each line (see there). A line asked for twice is drawn once."""

    def __init__(self):
        self.proc, self.known = None, {}

    def ask(self, text, face, px, draw=False):
        key = (text, face, px, draw)
        if key not in self.known:
            if self.proc is None:
                self.proc = subprocess.Popen(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy",
                                              "Bypass", "-File", os.path.join(HERE, "winrender.ps1")],
                                             stdin=subprocess.PIPE, stdout=subprocess.PIPE)
                if not json.loads(self.proc.stdout.readline() or b"{}").get("ready"):
                    raise RuntimeError("winrender.ps1 didn't start")
            request = {"text": text.replace(" ", face.space), "font": face.family, "px": px, "bold": face.bold,
                       "draw": draw}
            self.proc.stdin.write((json.dumps(request) + "\n").encode("ascii"))
            self.proc.stdin.flush()
            answer = json.loads(self.proc.stdout.readline() or b'{"error": "winrender.ps1 stopped"}')
            if "error" in answer:
                raise RuntimeError("%s: %s" % (ascii(text), answer["error"]))
            if os.path.basename(answer["font_file"]).lower() != face.file:
                raise RuntimeError("Windows has no %s here (it drew in %r)" % (face.family, answer["font_file"]))
            if draw:
                answer["mask"] = Image.open(io.BytesIO(base64.b64decode(answer.pop("png")))).getchannel("A")
            self.known[key] = answer
        return self.known[key]


WINDOWS = Windows()
MIDDLES = {}


def middle(face):
    """How far above its baseline a line's middle sits, against its size: the middle of a typical line's ink. Every
    line in a face shares it, so words side by side (three buttons) sit on one baseline."""
    if face not in MIDDLES:
        ink = WINDOWS.ask("اللاعب الآخر يشاهد", face, 100.0)["ink"]
        MIDDLES[face] = -(ink[1] + ink[3]) / 2 / 100
    return MIDDLES[face]


def width(text, face, px):
    """How long the line is at px (picture pixels)."""
    return WINDOWS.ask(text, face, px * K)["advance"] / K


def half(px):
    """px down to the half pixel (so a size asked for twice is the same size)."""
    return math.floor(px * 2 + 1e-6) / 2


def fit(text, face, px, room):
    """The size (picture pixels) at which the line fits room: px, or smaller, down to face.smallest."""
    px = max(face.smallest, half(px))
    while room and px > face.smallest:
        long = width(text, face, px)
        if long <= room:
            break
        px = max(face.smallest, min(px - 0.5, half(px * room / long)))
    return px


# Words a line shouldn't end on: they go with the word after them, as a number goes with its noun ("6 لاعبين").
CLINGY = set("في على إلى من عن مع بين أو و ثم لا لم لن قد حتى عند بلا دون لكن أي كل عبر هذا هذه أن إن ما".split())


def clingy(word):
    return word in CLINGY or bool(re.fullmatch(r"[0-9\u0660-\u0669]+", word))


def tokens(text):
    """The words to wrap by: English words side by side kept as one, as a name the game writes in English is
    ("Traversal Talisman", "New Game")."""
    out = []
    for word in text.split():
        english = bool(re.search("[A-Za-z]", word)) and not ARABIC.search(word)
        if english and out and out[-1][1]:
            out[-1] = (out[-1][0] + " " + word, True)
        else:
            out.append((word, english))
    return [word for word, _ in out]


def wrap(text, face, px, room, most):
    """The words in lines that fit room, at most `most` of them (two are made even), none ending on a word that
    belongs with the next, or None when they don't fit."""
    words = tokens(text)
    if width(text, face, px) <= room:
        return [text]
    if len(words) == 1 or most < 2:
        return None
    best = None
    for i in range(1, len(words)):
        a, b = " ".join(words[:i]), " ".join(words[i:])
        rank = (clingy(words[i - 1]), max(width(a, face, px), width(b, face, px)))
        if rank[1] <= room and (best is None or rank < best[0]):
            best = (rank, [a, b])
    if best and not best[0][0]:
        return best[1]
    lines, now = [], []
    for word in words:
        if now and width(" ".join(now + [word]), face, px) > room:
            carry = []
            while len(now) > 1 and clingy(now[-1]):
                carry.insert(0, now.pop())
            lines.append(" ".join(now))
            now = carry
        now.append(word)
    lines.append(" ".join(now))
    if len(lines) > most or any(width(x, face, px) > room for x in lines):
        return best[1] if best else None
    return lines


# ------------------------------------------------------------------ putting words on a picture

class Page:
    """A picture being worded, drawn K times bigger, and the lines put on it: each line's mask and place, and the room
    it was given, so the checks can tell when one runs out of its room, off the picture or into another line. inset:
    how far from the edge the ink must stay (past a frame's line)."""

    def __init__(self, img, keep_out=(), inset=2):
        self.img, self.keep_out, self.inset, self.lines, self.notes = img, keep_out, inset, [], []

    def put(self, mask, pos, color, room_box, text):
        x, y = pos
        left, top = max(0, -x), max(0, -y)
        right, bottom = min(mask.width, self.img.width - x), min(mask.height, self.img.height - y)
        if right > left and bottom > top:
            m = mask.crop((left, top, right, bottom))
            ink = Image.new("RGBA", m.size, color[:3] + (0,))
            ink.putalpha(m.point(lambda v: v * color[3] // 255))
            self.img.alpha_composite(ink, (x + left, y + top))
        self.lines.append((text, mask, pos, room_box))

    def drawn(self, how, text, room_box):
        """Words set by the generators' own code, how(d): on the picture, and once more alone for the checks."""
        how(ImageDraw.Draw(self.img))
        alone = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        how(ImageDraw.Draw(alone))
        self.lines.append((text, alone.getchannel("A"), (0, 0), room_box))


def line(page, text, at, size, face, color, align="right", room=None, gap=0, bold=False, px=None):
    """One line of words. at: (x, y) in the picture's own pixels: the line's right end, middle or left end (align), and
    its middle. size: the English words' size there; Arabic is set face.scale times bigger (or at px), then made smaller
    to fit room. Words with no Arabic letter in them (Steam, PvP) are set as the English pictures set them: Georgia,
    spaced out by gap. Gives back the size used."""
    x, y = at
    if not ARABIC.search(text):
        f = lp.font(size, bold)
        probe = ImageDraw.Draw(Image.new("L", (1, 1)))
        long = sum(probe.textlength(c, font=f) for c in text) + gap * K * (len(text) - 1)
        mask = Image.new("L", page.img.size, 0)
        lp.spaced(ImageDraw.Draw(mask), (x * K - {"right": long, "center": long / 2, "left": 0}[align], y * K), text, f,
                  255, gap=gap, anchor="lm")
        page.put(mask, (0, 0), color, room_box(at, align, room), text)
        return size
    wanted = px or size * face.scale
    px = fit(text, face, wanted, room)
    if px <= face.smallest < half(wanted):
        page.notes.append((text, "made as small as it goes (%g px) to fit: shorter words would read better" % px))
    a = WINDOWS.ask(text, face, px * K, draw=True)
    start = x * K + {"right": 0, "center": a["advance"] / 2, "left": a["advance"]}[align]
    base = y * K + middle(face) * px * K
    page.put(a["mask"], (round(start - a["x"]), round(base - a["y"])), color, room_box(at, align, room), text)
    return px


def room_box(at, align, room):
    """The stretch (left, right) a line was given, in the picture's own pixels."""
    if not room:
        return None
    x = at[0]
    return {"right": (x - room, x), "center": (x - room / 2, x + room / 2), "left": (x, x + room)}[align]


def block(page, rows, size, face, color, align="right"):
    """Lines that belong together (a page's labels, its help), each at its own place (x, y) and in its own room, all at
    one size: the biggest at which every one of them fits."""
    sizes = [fit(text, face, size * face.scale, room) for text, at, room in rows]
    for (text, at, room), own in zip(rows, sizes):
        if own <= face.smallest < half(size * face.scale):
            page.notes.append((text, "made as small as it goes (%g px) to fit: shorter words would read better" % own))
        line(page, text, at, size, face, color, align, room=room, px=min(sizes))


def column(page, items, right, top, bottom, room):
    """Lines one under another from top, right-aligned at right, as a tile's name and what it does: items are (text,
    English size, face, colour, most lines). All are made smaller together until they fit above bottom."""
    for shrink in [1 - i * 0.04 for i in range(13)]:
        laid, y, fits = [], top, True
        for n, (text, size, face, color, most) in enumerate(items):
            px = max(face.smallest, half(size * face.scale * shrink))
            lines = wrap(text, face, px, room, most)
            if lines is None:
                fits, lines = False, wrap(text, face, px, room, 99) or [text]
            step = face.lead * px
            if n:
                y += 4
            for words in lines:
                laid.append((words, (right, y + step / 2), size, px, face, color))
                y += step
        if fits and y <= bottom:
            break
    else:
        page.notes.append((None, "the words don't fit their room even at the smallest size"))
    if shrink < 1:
        page.notes.append((None, "its words made smaller than the other tiles' (%d%%) to fit" % round(shrink * 100)))
    for words, at, size, px, face, color in laid:
        line(page, words, at, size, face, color, room=room, bold=face.bold, px=px)
    return y


# ------------------------------------------------------------------ the checks

PROBLEMS = []


def check(name, page, size, words):
    """Each line inside the picture and its room, clear of the other lines and of what the mod draws over it. The
    messages name a line by its English (the table's key), as the console here may not show Arabic."""
    w, h = size

    def english(text):
        if text is None:
            return ""
        if not ARABIC.search(text):
            return "'%s' " % text
        whole = [en for en, ar in words.items() if text == ar] + [en for en, ar in words.items() if text in ar]
        return "'%s' " % (whole[0] if whole else "(the language button's own word)")

    for text, note in page.notes:
        PROBLEMS.append("%s: %s%s" % (name, english(text), note))
    masks = []
    for text, mask, pos, box in page.lines:
        bbox = mask.point(lambda v: 255 if v > 20 else 0).getbbox()
        if not bbox:
            continue
        ink = (bbox[0] + pos[0], bbox[1] + pos[1], bbox[2] + pos[0], bbox[3] + pos[1])
        l, t, r, b = (v / K for v in ink)
        say = english(text)
        i = page.inset
        if l < i or t < i or r > w - i or b > h - i:
            PROBLEMS.append("%s: %sruns off the picture or over its frame (ink %d,%d to %d,%d)"
                            % (name, say, l, t, r, b))
        if box and (l < box[0] - 1 or r > box[1] + 1):
            PROBLEMS.append("%s: %sruns out of its room (ink %d to %d, room %d to %d)" % (name, say, l, r, *box))
        for kl, kt, kr, kb in page.keep_out:
            if l < kr and r > kl and t < kb and b > kt:
                PROBLEMS.append("%s: %sruns under what the mod draws at %d,%d to %d,%d" % (name, say, kl, kt, kr, kb))
        full = Image.new("L", page.img.size, 0)
        full.paste(mask, pos)
        for other, said, ink2 in masks:
            near = ink[0] < ink2[2] and ink[2] > ink2[0] and ink[1] < ink2[3] and ink[3] > ink2[1]
            if near and ImageChops.multiply(full, other).point(lambda v: 255 if v > 20 else 0).getbbox():
                PROBLEMS.append("%s: %stouches %s" % (name, say, said))
        masks.append((full, say, ink))


# ------------------------------------------------------------------ the paper grain

NORMAL = [NormalDist().inv_cdf((i + 0.5) / 256) for i in range(256)]


def seeded_grain(name):
    """Pillow's effect_noise (the ink's paper grain) draws from the C library's unseeded rand(), so the English
    pictures grain anew each run. The Arabic ones draw it from a generator seeded with the picture's name: a rerun is
    the same."""
    rng = random.Random(name)

    def noise(size, sigma):
        flat = Image.frombytes("L", size, rng.randbytes(size[0] * size[1]))
        return flat.point([max(0, min(255, round(128 + sigma * z))) for z in NORMAL])
    Image.effect_noise = noise


# ------------------------------------------------------------------ the pictures

PICTURES = []       # (file name, the English words on it, which ids are its own in the table, how it's drawn, in pvp/)
F5, F6, MATCH = ("f5.art.", "f5more.art."), ("f6.art.",), ("match.",)
EN, PE = op.WORDS["en"], pv.WORDS["en"]


def picture(name, english, ids, draw, hud=False):
    PICTURES.append((name, english, ids, draw, hud))


# The online panel's main page and settings page: where the mod puts its own pictures and words over them
# (onlinepanel.lua).
KEEP_ONLINE = [(40, 18, 284, 48), (848, 14, 886, 52), (40, 112, 860, 198), (40, 244, 780, 302), (40, 350, 586, 396),
               (604, 344, 780, 402), (690, 494, 860, 540)]
KEEP_SETTINGS = [(848, 14, 886, 52), (41, 88, 859, 238), (124, 255, 775, 405), (40, 494, 210, 540)]


def online_bg(t):
    img, d = op.online_ground()
    page = Page(img, KEEP_ONLINE)
    line(page, t[EN["title"]], (450, 42), 25, TITLE, lp.BRIGHT, "center", room=320, gap=7)
    # Each label over the right end of what it names: the status box, the four ways in, the three buttons, the password.
    block(page, [(t[EN["status"]], (860, 96), 820), (t[EN["through"]], (780, 226), 740),
                 (t[EN["play"]], (586, 332), 546), (t[EN["password"]], (780, 332), 176)], 13, LABEL, lp.DIM)
    # The help: the last two lines stop short of MORE, down in the right corner.
    block(page, [(t[words], (860 if i < 3 else 680, y), 820 if i < 3 else 640)
                 for i, (y, words) in enumerate(zip((430, 452, 474, 496, 518), EN["help"]))], 13, BODY, lp.DIM)
    return page


def settings_bg(t):
    img, d = lp.ground()
    page = Page(img, KEEP_SETTINGS)
    line(page, t[EN["settings"]], (450, 42), 25, TITLE, lp.BRIGHT, "center", room=340, gap=7)
    block(page, [(t[words], (860, y), 630) for y, words in zip((505, 528), EN["foot"])], 12, BODY, lp.DIM)
    return page


def online_card(label, sub):
    def draw(t):
        img, d = lp.box(176, 58)
        page = Page(img)
        line(page, t[label], (162, 22), 15, LABEL, lp.BRIGHT, room=148)
        line(page, t[sub], (162, 42), 11, BODY, lp.DIM, room=148)
        return page
    return draw


def online_button(words, red):
    def draw(t):
        img, d, color = lp.button_ground(red)
        page = Page(img, inset=1)
        line(page, t[words], (85, 23), 16, LABEL, color, "center", room=150, gap=3, bold=True)
        return page
    return draw


def tile(label, sub, value, look, mark=None):
    """A setting's tile, mirrored: its name and what it does from the right, its value bottom right, after its mark."""
    def draw(t):
        img, d = op.tile_ground(look)
        title, small = op.LOOKS[look][2:]
        page = Page(img, inset=3)
        pad, size = 12, op.TILE
        base = size - pad - 9
        right = size - pad
        if op.tick_or_cross(d, right - 16, base, mark, title):
            right -= 22
        # A value in English (NEW GAME, a player count) gets the English tile's own size and letter gap.
        shown = t.get(value, value)
        big, gap = (14, 2) if ARABIC.search(shown) else op.value_size(d, shown, lp.font, right - pad)
        line(page, shown, (right, base), big, LABEL, title, room=right - pad, gap=gap, bold=True)
        column(page, [(t[label], 15, LABEL, title, 2), (t[sub], 11, BODY, small, 4)], size - pad, pad + 2, base - 12,
               size - 2 * pad)
        return page
    return draw


def language_button(t):
    img, d = lp.box(76, 30)
    page = Page(img)
    line(page, NATIVE, (38, 15), 13, PLAIN, lp.BRIGHT, "center", room=62)
    return page


def online_pictures():
    picture("ar_online_bg", [EN["title"], EN["status"], EN["through"], EN["play"], EN["password"]] + EN["help"], F5,
            online_bg)
    picture("ar_online_settings_bg", [EN["settings"]] + EN["foot"], F5, settings_bg)
    for name, (label, sub) in EN["cards"].items():
        picture("ar_" + name, [label, sub], F5, online_card(label, sub))
    b = EN["buttons"]
    for name, words, red in (("host", b["host"], False), ("join", b["join"], False), ("host_on", b["host"], True),
                             ("join_on", b["join"], True), ("leave", b["leave"], False),
                             ("settings", b["settings"], False), ("back", b["back"], False)):
        picture("ar_online_" + name, [words], F5, online_button(words, red))
    t = EN["tiles"]
    # (The Partner Compass tile is drawn in English and Chinese but shown by no panel since 1.6.6: none in Arabic.)
    for row in ("teleport", "pvp", "mapicon", "freetravel", "direct"):
        label, sub = t[row]
        picture("ar_tile_%s_on" % row, [label, sub, EN["on"]], F5, tile(label, sub, EN["on"], "on", "tick"))
        picture("ar_tile_%s_off" % row, [label, sub, EN["off"]], F5, tile(label, sub, EN["off"], "off", "cross"))
    label, sub = t["revive"]
    picture("ar_tile_revive_soon", [label, sub, EN["soon"]], F5, tile(label, sub, EN["soon"], "soon"))
    label, sub = t["players"]
    for n in ("2", "4", "6"):
        picture("ar_tile_players_" + n, [label, sub], F5, tile(label, sub, n, "multi"))
    label, sub = t["mode"]
    for value in ("multiplayer", "local"):
        picture("ar_tile_mode_" + value, [label, sub, EN[value]], F5, tile(label, sub, EN[value], "multi"))
    sw = EN["skip_words"]
    label, sub = t["skip"]
    picture("ar_tile_skip_todo", [label, sub, sw["todo"]], F5, tile(label, sub, sw["todo"], "off", "cross"))
    label, sub = t["skip_done"]
    picture("ar_tile_skip_done", [label, sub, sw["done"]], F5, tile(label, sub, sw["done"], "on", "tick"))
    picture("online_lang_ar", [], F5, language_button)


# The PvP page (F6) and its pick pages: where pvppanel.lua puts its own pictures and words over them.
KEEP_PVP = [(848, 14, 886, 52), (40, 118, 404, 176), (416, 118, 592, 176), (690, 124, 860, 170), (40, 204, 872, 308),
            (40, 372, 428, 538), (478, 370, 844, 506)]
KEEP_PICK = [(848, 14, 886, 52), (40, 90, 856, 322), (40, 494, 210, 540)]


def pvp_bg(t):
    img, d = pv.page_ground()
    page = Page(img, KEEP_PVP)
    line(page, t[PE["title"]], (450, 34), 28, TITLE, lp.BRIGHT, "center", room=300, gap=10)
    line(page, t[PE["sub"]], (450, 84), 10, BODY, lp.DIM, "center", room=820)
    # Each label over the right end of what it names: the two modes, the clock, the five arenas, the players' rows (to
    # their ticks), the loadout's cards.
    block(page, [(t[PE["mode"]], (404, 108), 364), (t[PE["clock"]], (592, 108), 176), (t[PE["arena"]], (872, 192), 832),
                 (t[PE["players"]], (428, 354), 388), (t[PE["loadout"]], (828, 354), 350)], 12, LABEL, lp.DIM)
    line(page, t[PE["foot"]], (450, 548), 10, BODY, lp.DIM, "center", room=820)
    return page


def pick_bg(words):
    def draw(t):
        img, d = lp.ground()
        page = Page(img, KEEP_PICK)
        line(page, t[words], (450, 42), 22, TITLE, lp.BRIGHT, "center", room=600, gap=6)
        return page
    return draw


def pvp_card(name, sub, w, h, accent):
    """A mode's or a clock's card: its name from the right, and a line under it. The name stays on one line, made
    smaller as far as it reads well (two cramped lines read worse); two lines only past that."""
    def draw(t):
        img, d = pv.card_ground(w, h, accent)
        page = Page(img)
        right, room = w - 14, w - 22
        px = fit(t[name], LABEL, 13 * LABEL.scale, room)
        lines = [t[name]]
        if width(t[name], LABEL, px) > room:
            lines = wrap(t[name], LABEL, px, room, 2) or lines
        step, sub_px = LABEL.lead * px, half(max(BODY.smallest, 9 * BODY.scale))
        high = step * len(lines) + 2 + BODY.lead * sub_px
        y = (h - high) / 2 + step / 2
        for words in lines:
            line(page, words, (right, y), 13 if len(lines) == 1 else 11, LABEL, lp.BRIGHT, room=room, px=px)
            y += step
        line(page, t[sub], (right, y - step / 2 + 2 + BODY.lead * sub_px / 2), 9, BODY, lp.DIM, room=room, px=sub_px)
        return page
    return draw


def pvp_slot(words):
    def draw(t):
        img, d = lp.canvas(176, 18)
        page = Page(img, inset=0)
        line(page, t[words], (158, 9), 10, LABEL, lp.DIM, room=156)      # flush with the 160-wide card under it
        return page
    return draw


def pvp_row(slot):
    """A player's row on the page: their colour's dot, then their name where the English one is, by the dot (the
    team's tag and the tick follow on the right)."""
    def draw(t):
        img, d = pv.row_ground(slot)
        page = Page(img, inset=0)
        line(page, t["PLAYER %d"].replace("%d", str(slot)), (26, 13), 12, LABEL, lp.BRIGHT, "left", room=222,
             bold=True)
        return page
    return draw


def pvp_button(words, red=False, faded=False):
    def draw(t):
        img, d, color = pv.button_ground(red, faded)
        page = Page(img)
        line(page, t[words], (85, 23), 15, LABEL, color, "center", room=150, gap=4)
        return page
    return draw


def pvp_team(team):
    def draw(t):
        img, d = pv.team_ground(team)
        page = Page(img)
        line(page, t[PE["teams"][team]], (48, 12), 10, LABEL, lp.BRIGHT, "center", room=88, gap=2, bold=True)
        return page
    return draw


def arena_card(key, name, sub, locked, pics):
    """An arena's card: its picture and band, its name on the band, the reason it's locked under it. An arena's name
    stays as the game writes it, in English (the user's call: the game has no Arabic), set as the English card sets it,
    and the Arabic under it goes from that name's left edge. Here (هنا) is Arabic, from the right."""
    def draw(t):
        img = pv.arena_ground(key, locked, pics)
        page = Page(img)
        w, h = 160, 104
        if ARABIC.search(t[name]):
            line(page, t[name], (152, h - 24 if sub else h - 14), 12, LABEL, lp.BRIGHT if not locked else lp.DIM,
                 room=144, bold=True)
            at, align = (152, h - 9), "right"
        else:
            page.drawn(lambda d: pv.arena_name(d, t[name], lp.font, locked, sub), t[name], (8, 152))
            at, align = (8, h - 9), "left"
        if sub:
            line(page, t[sub], at, 9, BODY, (220, 120, 110, 255) if locked else lp.DIM, align, room=144)
        lp.frame(ImageDraw.Draw(img), w, h, lp.FAINT)
        return page
    return draw


def pvp_pictures():
    picture("ar_pvp_bg", [PE[k] for k in ("title", "sub", "mode", "clock", "arena", "players", "loadout", "foot")], F6,
            pvp_bg)
    for kind in ("main", "edge"):
        picture("ar_pvp_pick_" + kind, [PE["pick"][kind]], F6, pick_bg(PE["pick"][kind]))
    for key, (name, sub) in PE["modes"].items():
        picture("ar_pvp_mode_" + key, [name, sub], F6, pvp_card(name, sub, 176, 58, pv.BLOOD))
    for key, (name, sub) in PE["clocks"].items():
        picture("ar_pvp_clock_" + key, [name, sub], F6, pvp_card(name, sub, 176, 58, None))
    for key, words in PE["slots"].items():
        picture("ar_pvp_slot_" + key, [words], F6, pvp_slot(words))
    for key, words in PE["buttons"].items():
        picture("ar_pvp_" + key, [words], F6, pvp_button(words, red=key in ("ready_on", "start")))
    picture("ar_pvp_start_off", [PE["buttons"]["start"]], F6, pvp_button(PE["buttons"]["start"], faded=True))
    for team in (1, 2):
        picture("ar_pvp_team_%d" % team, [PE["teams"][team]], F6, pvp_team(team))
    for slot in sorted(pv.PLAYERS):
        picture("ar_pvp_row_%d" % slot, ["PLAYER %d"], F6, pvp_row(slot))
    pics = pv.arena_photos()
    here, where = PE["here"]
    picture("ar_pvp_arena_here", [here, where], F6, arena_card("here", here, where, False, pics))
    for key, name, _ in pv.ARENAS:
        picture("ar_pvp_arena_" + key, [name], F6, arena_card(key, name, None, False, pics))
        picture("ar_pvp_arena_%s_locked" % key, [name, PE["locked"]], F6,
                arena_card(key, name, PE["locked"], True, pics))
    # (No weapon cards: they keep the game's own names, so the English ones show in Arabic too: pvppanel.lua's named().)


def banner(key):
    """The words across the screen between rounds, on the same smear, with the same soft shadow under them."""
    def draw(t):
        img = pv.banner_ground(key)
        words = Page(Image.new("RGBA", img.size, (0, 0, 0, 0)))
        line(words, t[pv.BANNERS[key][0]], (450, 75), 38, BANNER, pv.banner_ink(key), "center", room=800, gap=12,
             bold=True)
        shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
        shadow.putalpha(words.img.getchannel("A").point(lambda v: v * 220 // 255))
        img.alpha_composite(shadow.transform(img.size, Image.AFFINE, (1, 0, -2 * K, 0, 1, -2 * K))
                            .filter(ImageFilter.GaussianBlur(3 * K)))
        img.alpha_composite(words.img)
        words.img = img
        return words
    return draw


def mate(slot):
    """A teammate's name over their bar: their colour's dot, then the name, held to the left with the bar under it."""
    def draw(t):
        img, d = pv.mate_ground(slot)
        page = Page(img, inset=0)
        line(page, t["PLAYER %d"].replace("%d", str(slot)), (16, 11), 12, LABEL, pv.BONE, "left", room=132, gap=2,
             bold=True)
        return page
    return draw


def match_pictures():
    for key, (en, _) in pv.BANNERS.items():
        picture("ar_banner_" + key, [en], MATCH, banner(key), hud=True)
    for slot in sorted(pv.PLAYERS):
        picture("ar_mate_%d" % slot, ["PLAYER %d"], MATCH, mate(slot), hud=True)


# ------------------------------------------------------------------ arabic.tsv

class Words:
    """The table's Arabic, by the English it stands for. A row with no Arabic doesn't count. When one English has more
    than one Arabic, a row whose id is the picture's own kind (f5.art., f6.art., match., ...) comes first."""

    def __init__(self, path):
        self.rows = {}
        with open(path, encoding="utf-8-sig") as fh:
            head = None
            for raw in fh:
                cells = raw.rstrip("\r\n").split("\t")
                if head is None:
                    head = [c.strip().lower() for c in cells]
                    if "english" not in head or "arabic" not in head:
                        raise SystemExit("%s: no english and arabic columns in its first line" % path)
                    continue
                row = dict(zip(head, cells))
                en, ar = (row.get("english") or "").strip(), (row.get("arabic") or "").strip()
                if en and ar:
                    self.rows.setdefault(en, []).append(((row.get("id") or "").strip(), ar))
        self.loose = {}
        for en, rows in self.rows.items():
            self.loose.setdefault(" ".join(en.lower().split()), rows)

    def get(self, english, ids):
        rows = self.rows.get(english) or self.loose.get(" ".join(english.lower().split()))
        if not rows:
            return None
        for start in ids + (".art.",):
            for rid, ar in rows:
                if rid.startswith(start) or (start == ".art." and start in rid):
                    return ar
        return rows[0][1]


def main(args):
    sys.stdout.reconfigure(errors="replace")
    tables = [a for a in args if a.lower().endswith(".tsv")]      # (the table wherever it is given, once)
    if len(tables) > 1:
        raise SystemExit("one table at most: " + ", ".join(tables))
    tsv = tables[0] if tables else os.path.join(HERE, "arabic.tsv")
    only = set(a.replace(".png", "") for a in args if not a.lower().endswith(".tsv"))
    if not os.path.exists(tsv):
        raise SystemExit("no %s: give the path to the table (arabic.tsv)" % tsv)
    ar = Words(tsv)
    online_pictures()
    pvp_pictures()
    match_pictures()
    made, skipped = [], []
    for name, english, ids, draw, hud in PICTURES:
        if only and name not in only:
            continue
        assert name.startswith("ar_") or name == "online_lang_ar"
        t, missing = {}, []
        for words in english:
            got = ar.get(words, ids)
            if got is None:
                missing.append(words)
            elif "%d" in words and "%d" not in got:
                missing.append(words + " (its Arabic has no %d for the number)")
            else:
                t[words] = got
        if missing:
            skipped.append((name, missing))
            continue
        seeded_grain(name)
        page = draw(t)
        check(name, page, (page.img.width // K, page.img.height // K), t)
        (pv.save_hud if hud else lp.save)(page.img, name)
        made.append(name)
    print("Arabic pictures written: %d (to %s and %s)"
          % (len(made), os.path.normpath(lp.OUT), os.path.normpath(pv.HUD)))
    if skipped:
        print("Skipped, no Arabic yet for their words: %d" % len(skipped))
        for name, missing in skipped:
            print("  %s: %s" % (name, " | ".join(missing)))
    if PROBLEMS:
        print("To look at: %d" % len(PROBLEMS))
        for p in PROBLEMS:
            print("  " + p)


if __name__ == "__main__":
    main(sys.argv[1:])
