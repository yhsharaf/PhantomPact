"""Builds PvP's pictures (mod/PBZCoop/art/panel/pvp_* and mod/PBZCoop/art/pvp/*): the F6 page in the panels' own look, and the
match's banners, bars and effects. The countdown's 三 二 一 and 斗 are text in the game's own brush font now (arenaui.lua);
here are the crimson ink ring under them, the wash that keeps them readable and the last screens' glow, embers and ash, in
the game's black, bone and blood. Arena cards come from the game's own arenas, photographed on the bench (art/pvp_src).
Needs Pillow and Windows' Microsoft YaHei: python art/make_pvp_art.py (python art/make_pvp_art.py fx: the effects only)"""
import math
import os
import random
import re

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

from make_local_panel import (BLACK, BRIGHT, DIM, FAINT, FONTS, K, OUT, SILVER, canvas, corners, font, frame, save,
                              selected, spaced)

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "pvp_src")
HUD = os.path.join(HERE, "..", "mod", "PBZCoop", "art", "pvp")
os.makedirs(HUD, exist_ok=True)

BONE = (238, 232, 220, 255)
BLOOD = (168, 22, 26, 255)
DEEP = (110, 12, 16, 255)
CRIMSON = (204, 40, 44, 255)
AZURE = (64, 140, 222, 255)
GOLD = (232, 184, 72, 255)
TEAM = {1: CRIMSON, 2: AZURE}
PLAYERS = {1: ((176, 120, 255), "PLAYER 1"), 2: ((96, 210, 120), "PLAYER 2"), 3: ((236, 196, 64), "PLAYER 3"),
           4: ((90, 172, 255), "PLAYER 4"), 5: ((255, 128, 40), "PLAYER 5"), 6: ((255, 115, 190), "PLAYER 6")}


def chinese(size, bold=False):
    return ImageFont.truetype(FONTS + ("msyhbd.ttc" if bold else "msyh.ttc"), size * K)


def save_hud(img, name):
    w, h = img.size
    img.resize((max(1, w // K), max(1, h // K)), Image.LANCZOS).save(os.path.join(HUD, name + ".png"))


def label(d, xy, text, face, size, fill, gap=3, anchor="lm", bold=False):
    """Small caps in Georgia are spaced out; Chinese is set as it is."""
    if face is font:
        spaced(d, xy, text, face(size, bold), fill, gap=gap, anchor=anchor)
    else:
        d.text(xy, text, font=face(size, bold), fill=fill, anchor="mm" if anchor == "mm" else "lm")


# ------------------------------------------------------------------ the brush

def catmull(points, steps=40):
    """A smooth path through the points."""
    out = []
    pts = [points[0]] + points + [points[-1]]
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for s in range(steps):
            t = s / steps
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    out.append(points[-1])
    return out


def resample(path, step):
    """The path again, a point every `step` pixels along it: dense enough that no bristle shows as dots."""
    out = [path[0]]
    carry = 0.0
    for i in range(len(path) - 1):
        x0, y0 = path[i]
        x1, y1 = path[i + 1]
        seg = math.hypot(x1 - x0, y1 - y0)
        if seg <= 0:
            continue
        d = step - carry
        while d <= seg:
            f = d / seg
            out.append((x0 + (x1 - x0) * f, y0 + (y1 - y0) * f))
            d += step
        carry = seg - (d - step)
    out.append(path[-1])
    return out


def stroke(mask, points, widths, rng, bristles=46, dry=0.25):
    """One brush stroke into an L mask: bristles side by side across the width, each its own thickness and wander, running
    out a little early or late; near the end of a dry stroke they break off in clumps: the dry brush's streaks."""
    path = catmull(points, 24)
    base = max(1.0, max(widths) / bristles * 0.9)
    path = resample(path, base * 0.6)
    n = len(path)
    wid = []
    for i in range(n):
        f = i / max(1, n - 1) * (len(widths) - 1)
        a = int(f)
        b = min(a + 1, len(widths) - 1)
        wid.append(widths[a] + (widths[b] - widths[a]) * (f - a))
    d = ImageDraw.Draw(mask)
    lanes = []
    for _ in range(bristles):
        lanes.append({
            "off": rng.uniform(-0.5, 0.5),
            "size": rng.uniform(0.7, 1.6),
            "amp": rng.uniform(0.0, 0.035), "freq": rng.uniform(3, 11), "phase": rng.uniform(0, 6.3),
            "end": 1.0 - abs(rng.gauss(0, dry * 0.35)),
            "thirst": rng.random() ** 2,            # how soon this one runs dry
            "clump": rng.uniform(4, 14), "cphase": rng.uniform(0, 6.3),
            "ink": rng.uniform(0.82, 1.0),
        })
    for i in range(n - 1):
        x0, y0 = path[i]
        x1, y1 = path[i + 1]
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length
        t = i / max(1, n - 1)
        w = wid[i]
        late = max(0.0, (t - 0.45) / 0.55)
        for ln in lanes:
            if t > ln["end"]:
                continue
            # Dry: a bristle breaks off in clumps, more of them the further along and the thirstier it is.
            gap = 0.5 + 0.5 * math.sin(t * ln["clump"] * 6.3 + ln["cphase"])
            if gap < dry * ln["thirst"] * late * 2.2:
                continue
            off = ln["off"] + ln["amp"] * math.sin(t * ln["freq"] * 6.3 + ln["phase"])
            x = x0 + nx * off * w
            y = y0 + ny * off * w
            r = max(1.0, w / bristles * 1.35 * ln["size"])
            d.ellipse((x - r, y - r, x + r, y + r), fill=int(255 * ln["ink"]))


def ink(mask, color, bleed=True):
    """The mask as ink: rough-edged where it soaks into the paper's grain, with a soft bleed around it."""
    grain = Image.effect_noise(mask.size, 64).filter(ImageFilter.GaussianBlur(0.8))
    a = mask.filter(ImageFilter.GaussianBlur(1.6))
    a = Image.blend(a, grain, 0.18)
    a = a.point(lambda v: 255 if v > 132 else (0 if v < 70 else int((v - 70) * 4)))
    layer = Image.new("RGBA", mask.size, color[:3] + (0,))
    layer.putalpha(a)
    if bleed:
        soft = mask.filter(ImageFilter.GaussianBlur(10)).point(lambda v: int(v * 0.26))
        under = Image.new("RGBA", mask.size, color[:3] + (0,))
        under.putalpha(soft)
        under.alpha_composite(layer)
        return under
    return layer


def enso(size, rng, color=DEEP):
    """The ink circle behind each number: one sweep, open at the top right, thick then running dry."""
    m = Image.new("L", (size, size), 0)
    c, r = size / 2, size * 0.40
    start, sweep = math.radians(-50), math.radians(318)
    pts = []
    for i in range(12):
        a = start + sweep * i / 11
        rr = r * (1 + 0.025 * math.sin(i * 1.7))
        pts.append((c + rr * math.cos(a), c + rr * math.sin(a)))
    ws = [size * 0.035, size * 0.075, size * 0.085, size * 0.08, size * 0.075, size * 0.07, size * 0.065, size * 0.06,
          size * 0.05, size * 0.04, size * 0.03, size * 0.012]
    stroke(m, pts, ws, rng, bristles=70, dry=0.55)
    return ink(m, color)


def caption(text, size=34, color=BONE, gap=10, face=None, w=None, bold=True):
    f = (face or font)(size, bold)
    probe = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
    if (face or font) is font:
        tw = sum(probe.textlength(c, font=f) for c in text) + gap * K * (len(text) - 1)
    else:
        tw = probe.textlength(text, font=f)
    W = int(w * K) if w else int(tw + 40 * K)
    img = Image.new("RGBA", (W, int(size * 1.9 * K)), (0, 0, 0, 0))
    # A shadow first, so the words read over a bright sky.
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    d = ImageDraw.Draw(img)
    mid = (W / 2, img.size[1] / 2)
    if (face or font) is font:
        spaced(sd, (mid[0] + 2 * K, mid[1] + 2 * K), text, f, (0, 0, 0, 220), gap=gap)
        img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(3 * K)))
        spaced(d, mid, text, f, color, gap=gap)
    else:
        sd.text((mid[0] + 2 * K, mid[1] + 2 * K), text, font=f, fill=(0, 0, 0, 220), anchor="mm")
        img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(3 * K)))
        d.text(mid, text, font=f, fill=color, anchor="mm")
    return img


def radial(size, f, step=4):
    """An L mask of size (w, h) whose value at each point is 255 * f(r), r the distance from the middle against the
    half-diagonal (0 in the middle, 1 at the corners); worked out every `step` pixels."""
    w, h = size
    m = Image.new("L", (w, h), 0)
    px = m.load()
    hd = math.hypot(w / 2, h / 2)
    for y in range(0, h, step):
        for x in range(0, w, step):
            v = int(255 * max(0.0, min(1.0, f(math.hypot(x - w / 2, y - h / 2) / hd))))
            for yy in range(min(step, h - y)):
                for xx in range(min(step, w - x)):
                    px[x + xx, y + yy] = v
    return m


def fx():
    """The countdown's and the last screens' effects (11-09, the user: "no visual effects", "not looking HD", hard to read
    against the scene; then, of bursts, droplets and rays, "kidish and cartoonish"). White masks, tinted in the game
    (crimson, blood, gold), and drawn big: the wash behind the numbers, the ring, a glow, an ember, a flake of ash and the
    screen's edge. The numbers themselves are text in the game's own brush font (arenaui.lua), sharp at any size, and the
    finishing blow has the game's own 斩."""
    from PIL import ImageChops
    white = (255, 255, 255, 255)
    rng = random.Random(1109)
    S = 1024 * K
    c = S / 2
    # The wash: a soft ink blot behind the numbers, so they read over moss, rock or sky.
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    for _ in range(14):
        a, rr = rng.uniform(0, 6.3), rng.uniform(0.0, 0.12) * S
        r = rng.uniform(0.17, 0.27) * S
        x, y = c + rr * math.cos(a), c + rr * math.sin(a)
        d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    m = m.filter(ImageFilter.GaussianBlur(S * 0.06))
    grain = Image.effect_noise((S, S), 90).filter(ImageFilter.GaussianBlur(S * 0.004))
    m = Image.blend(m, grain, 0.10).point(lambda v: int(min(255, max(0, (v - 20) * 1.15)) * 0.86))
    wash = Image.new("RGBA", (S, S), (6, 4, 6, 0))
    wash.putalpha(m)
    save_hud(wash, "fx_wash")
    # The ring, one sweep of the brush as before, white now and four times the pixels.
    save_hud(enso(S, random.Random(43), color=white), "fx_ring")
    # A glow (the light behind 生还 and 殒命) and an ember (a bright core in a soft halo).
    for name, G, f in (("fx_glow", 512 * K, lambda r: math.exp(-(r / 0.42) ** 2)),
                       ("fx_ember", 64 * K, lambda r: 0.55 * math.exp(-(r / 0.3) ** 2) + 1.4 * math.exp(-(r / 0.1) ** 2))):
        img = Image.new("RGBA", (G, G), white[:3] + (0,))
        img.putalpha(radial((G, G), f, step=K))
        save_hud(img, name)
    # Ash for the fallen: a torn flake, soft at its edge, a little see-through in places.
    A = 64 * K
    m = Image.new("L", (A, A), 0)
    d = ImageDraw.Draw(m)
    pts = []
    for i in range(11):
        a = i / 11 * 6.283 + rng.uniform(-0.15, 0.15)
        r = A * rng.uniform(0.2, 0.36) * (1.0 if i % 3 else 0.62)
        pts.append((A / 2 + r * math.cos(a) * 1.2, A / 2 + r * math.sin(a) * 0.78))
    d.polygon(pts, fill=255)
    grain = Image.effect_noise((A, A), 70).filter(ImageFilter.GaussianBlur(A * 0.02))
    m = ImageChops.multiply(m.filter(ImageFilter.GaussianBlur(A * 0.025)), grain.point(lambda v: min(255, 90 + v)))
    flake = Image.new("RGBA", (A, A), white[:3] + (0,))
    flake.putalpha(m)
    save_hud(flake, "fx_ash")
    # The screen's edge: clear in the middle, full at the corners (the red flash of 斗, the fallen's pulse).
    def edge(r):
        t = min(1.0, max(0.0, (r - 0.35) / 0.65))
        return t * t * (3 - 2 * t)
    vig = Image.new("RGBA", (1024 * K, 576 * K), white[:3] + (0,))
    vig.putalpha(radial((1024 * K, 576 * K), edge, step=6).filter(ImageFilter.GaussianBlur(4)))
    save_hud(vig, "fx_vignette")


def smear(w, h, color, seed):
    rng = random.Random(seed)
    m = Image.new("L", (w, h), 0)
    y = h * 0.5
    stroke(m, [(w * 0.03, y + h * 0.05), (w * 0.2, y - h * 0.02), (w * 0.5, y), (w * 0.8, y + h * 0.03), (w * 0.97, y)],
           [h * 0.3, h * 0.62, h * 0.7, h * 0.6, h * 0.25], rng, bristles=90, dry=0.6)
    return ink(m, color, bleed=False)


def banners(only=None):
    """Words across the screen between rounds, on an ink smear. only: just these keys (the rest left as they are)."""
    sets = {
        "round_1": ("ROUND ONE", "第一回合"), "round_2": ("ROUND TWO", "第二回合"), "round_3": ("FINAL ROUND", "决胜回合"),
        "death": ("ONE LIFE", "一命定胜负"),
        "round_won": ("ROUND TAKEN", "本回合胜"), "round_lost": ("ROUND LOST", "本回合负"), "round_draw": ("DRAW", "平局"),
        "down": ("YOU'RE DOWN", "你倒下了"), "fell": ("YOU FELL", "你坠落了"),
        "finish": ("PRESS F TO FINISH", "按 F 处决"),
        # (The host's, on the last screens: a rematch where they stand, issue #13.)
        "again": ("PRESS F TO REMATCH", "按 F 再战一场"),
        "won": ("YOUR TEAM WINS", "你的队伍获胜"), "lost": ("YOUR TEAM FALLS", "你的队伍落败"),
        # (One on one: it's you, not a team.)
        "won_one": ("YOU WIN", "你获胜"), "lost_one": ("YOU FALL", "你落败"),
    }
    dark = ("round_lost", "lost", "lost_one", "down", "fell")
    for key, (en, zh) in sets.items():
        if only and key not in only:
            continue
        for prefix, text, face in (("", en, font), ("zh_", zh, chinese)):
            W, H = 900, 150
            img = Image.new("RGBA", (W * K, H * K), (0, 0, 0, 0))
            img.alpha_composite(smear(W * K, H * K, DEEP if key in dark else (20, 18, 20, 255), sum(map(ord, key))))
            color = CRIMSON if key == "finish" else (GOLD if key in ("won", "won_one", "round_won") else BONE)
            words = caption(text, 38, color, gap=12, face=face, w=W)
            img.alpha_composite(words, (0, (H * K - words.size[1]) // 2))
            save_hud(img, prefix + "banner_" + key)


# (The match's health bars, its score strip and clock digits were ours once: the foes are on the game's own boss bar now,
# the score and the clock in its own name text, as the user asked: health bars in the game's own design.)


# ------------------------------------------------------------------ the F6 page

WORDS = {
    "en": {
        "prefix": "", "face": font, "title": "PvP", "sub": "DUELS IN THE ARENAS OF THE BOSSES YOU HAVE BEATEN",
        "mode": "MODE", "clock": "CLOCK", "arena": "ARENA", "players": "PLAYERS", "loadout": "YOUR LOADOUT",
        "modes": {"duel": ("Duel", "Best of three rounds"), "death": ("Death", "One life, last team standing")},
        "clocks": {"0": ("No Timer", "Fight to the fall"), "60": ("60 s a round", "Most health left wins"),
                   "90": ("90 s a round", "Most health left wins"), "120": ("120 s a round", "Most health left wins")},
        "slots": {"main1": "WEAPON I", "main2": "WEAPON II", "edge1": "PHANTOM EDGE I", "edge2": "PHANTOM EDGE II"},
        "pick": {"main": "CHOOSE A WEAPON", "edge": "CHOOSE A PHANTOM EDGE"},
        "buttons": {"ready": "READY", "ready_on": "READY", "start": "START", "leave": "LEAVE", "back": "BACK"},
        "teams": {1: "CRIMSON", 2: "AZURE"},
        "foot": "Everyone fights at the top of the game: every skill, weapons at level 30, three drinks from one gourd, no talismans.",
        "locked": "Beat this boss first", "here": ("Here", "Where the host stands"),
        "kinds": {"blade": "BLADE", "twin": "TWIN BLADES", "great": "GREATBLADE", "combat": "COMBAT", "damage": "DAMAGE",
                  "stunt": "STUNT", "magic": "TRICKERY", "summon": "SUMMON"},
    },
    "zh": {
        "prefix": "zh_", "face": chinese, "title": "PvP", "sub": "在你击败过的首领战场上一决高下",
        "mode": "模式", "clock": "时限", "arena": "战场", "players": "玩家", "loadout": "你的配装",
        "modes": {"duel": ("决斗", "三局两胜"), "death": ("死斗", "一条命,最后的队伍获胜")},
        "clocks": {"0": ("不限时", "打到倒下为止"), "60": ("每回合 60 秒", "剩余血量多者胜"),
                   "90": ("每回合 90 秒", "剩余血量多者胜"), "120": ("每回合 120 秒", "剩余血量多者胜")},
        "slots": {"main1": "武器 一", "main2": "武器 二", "edge1": "杀器 一", "edge2": "杀器 二"},
        "pick": {"main": "选择武器", "edge": "选择杀器"},
        "buttons": {"ready": "准备", "ready_on": "已准备", "start": "开始", "leave": "离开", "back": "返回"},
        "teams": {1: "赤队", 2: "青队"},
        "foot": "所有人以满级状态对战:全部技能,武器 30 级,同一个葫芦只能喝三口,不戴护符。",
        "locked": "先击败此首领", "here": ("此地", "房主所在之处"),
        "kinds": {"blade": "刀", "twin": "双刃", "great": "重刃", "combat": "战技", "damage": "重击", "stunt": "奇技",
                  "magic": "幻术", "summon": "召唤"},
    },
}

ARENAS = [("yucong", "Crimson Forest", "赤林"), ("huaqianxiao", "Hua Qianxiao's Stage", "花千笑之台"),
          ("goldmask", "The Gold-Masked Gorge", "金面人之谷"), ("muxiaokui", "Mu Xiaokui's Meadow", "木小葵之野")]


def page_bg(wd):
    W, H = 900, 560
    img, d = canvas(W, H)
    d.rectangle((0, 0, W * K, H * K), fill=BLACK)
    frame(d, W, H, FAINT)
    corners(d, W, H)
    face = wd["face"]
    rng = random.Random(5)
    m = Image.new("L", (W * K, 30 * K), 0)
    stroke(m, [(360 * K, 18 * K), (450 * K, 14 * K), (540 * K, 17 * K)], [5 * K, 9 * K, 3 * K], rng, bristles=40, dry=0.5)
    img.alpha_composite(ink(m, BLOOD, bleed=False), (0, 46 * K))
    spaced(d, (W * K / 2, 34 * K), wd["title"], font(28), BRIGHT, gap=10)
    d.text((W * K / 2, 84 * K), wd["sub"], font=face(10), fill=DIM, anchor="mm")
    label(d, (40 * K, 108 * K), wd["mode"], face, 12, DIM)
    label(d, (416 * K, 108 * K), wd["clock"], face, 12, DIM)
    label(d, (40 * K, 192 * K), wd["arena"], face, 12, DIM)
    d.line((40 * K, 338 * K, 860 * K, 338 * K), fill=FAINT, width=K)
    label(d, (40 * K, 354 * K), wd["players"], face, 12, DIM)
    label(d, (478 * K, 354 * K), wd["loadout"], face, 12, DIM)
    d.text((W * K / 2, 548 * K), wd["foot"], font=face(10), fill=DIM, anchor="mm")
    save(img, wd["prefix"] + "pvp_bg")
    for kind in ("main", "edge"):
        img, d = canvas(W, H)
        d.rectangle((0, 0, W * K, H * K), fill=BLACK)
        frame(d, W, H, FAINT)
        corners(d, W, H)
        label(d, (W * K / 2, 42 * K), wd["pick"][kind], face, 22, BRIGHT, gap=6, anchor="mm")
        d.line(((W / 2 - 170) * K, 67 * K, (W / 2 + 170) * K, 67 * K), fill=FAINT, width=K)
        save(img, wd["prefix"] + "pvp_pick_" + kind)


def wrap(text, face, size, width):
    """The words in one or two lines that fit."""
    f = face(size)
    probe = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
    if probe.textlength(text, font=f) <= width or " " not in text:
        return [text]
    words = text.split(" ")
    best = None
    for i in range(1, len(words)):
        a, b = " ".join(words[:i]), " ".join(words[i:])
        wa, wb = probe.textlength(a, font=f), probe.textlength(b, font=f)
        if best is None or max(wa, wb) < best[0]:
            best = (max(wa, wb), [a, b])
    return best[1]


def card(name, text, sub, face, w=176, h=58, accent=None):
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(26, 27, 31, 240))
    frame(d, w, h)
    if accent:
        d.rectangle((K, K, 4 * K, h * K - K), fill=accent)
    size = 13 if face is font else 14
    lines = wrap(text, face, size, (w - 22) * K)
    if len(lines) > 1:
        size = 11 if face is font else 12
        lines = wrap(text, face, size, (w - 22) * K)
    top = h / 2 - (7 if sub else 0) - (len(lines) - 1) * 6.5
    for i, line in enumerate(lines):
        d.text((14 * K, (top + i * 13) * K), line, font=face(size), fill=BRIGHT, anchor="lm")
    if sub:
        d.text((14 * K, (top + (len(lines) - 1) * 13 + 17) * K), sub, font=face(9), fill=DIM, anchor="lm")
    save(img, name)


def button(name, text, face, w=170, h=46, red=False, faded=False):
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(150, 26, 22, 235) if red else (26, 27, 31, 240))
    frame(d, w, h, SILVER if not faded else FAINT)
    label(d, (w * K / 2, h * K / 2), text, face, 15, BRIGHT if not faded else DIM, gap=4, anchor="mm")
    save(img, name)


def arena_cards(wd):
    """An arena's card: its own picture (photographed on the bench), darkened, its name on an ink band. Locked: grey."""
    w, h = 160, 104
    pics = {}
    for key, _, _ in ARENAS:
        p = os.path.join(SRC, key + ".jpg")
        if os.path.exists(p):
            pics[key] = Image.open(p).convert("RGBA")
    crops = {"yucong": (0.02, 0.16, 0.80, 0.86), "huaqianxiao": (0.0, 0.10, 0.62, 0.75), "goldmask": (0.08, 0.06, 0.92, 0.80),
             "muxiaokui": (0.38, 0.10, 1.0, 0.75)}
    face = wd["face"]
    for key, en, zh in [("here", "", "")] + ARENAS:
        for locked in (False, True):
            if key == "here" and locked:
                continue
            img, d = canvas(w, h)
            if key in pics:
                src = pics[key]
                sw, sh = src.size
                c = crops[key]
                pic = src.crop((int(c[0] * sw), int(c[1] * sh), int(c[2] * sw), int(c[3] * sh)))
                pic = pic.resize((w * K, h * K), Image.LANCZOS)
                pic = ImageEnhance.Brightness(pic).enhance(0.9 if not locked else 0.4)
                if locked:
                    pic = ImageEnhance.Color(pic).enhance(0.08)
                img.alpha_composite(pic)
            else:
                d.rectangle((0, 0, w * K, h * K), fill=(18, 16, 18, 255))
                img.alpha_composite(enso(h * K, random.Random(9), color=DEEP), ((w - h) * K // 2, -12 * K))
            band = Image.new("RGBA", (w * K, 40 * K), (0, 0, 0, 0))
            bd = ImageDraw.Draw(band)
            for y in range(40 * K):
                bd.line((0, y, w * K, y), fill=(0, 0, 0, int(30 + 200 * y / (40 * K))))
            img.alpha_composite(band, (0, (h - 40) * K))
            d = ImageDraw.Draw(img)
            if key == "here":
                text, sub = wd["here"]
            else:
                text = en if face is font else zh
                sub = wd["locked"] if locked else None
            size = 12 if len(text) <= 20 else 11
            d.text((8 * K, (h - 22) * K if sub else (h - 13) * K), text, font=face(size, True),
                   fill=BRIGHT if not locked else DIM, anchor="lm")
            if sub:
                d.text((8 * K, (h - 8) * K), sub, font=face(9), fill=(220, 120, 110, 255) if locked else DIM, anchor="lm")
            frame(d, w, h, FAINT)
            save(img, wd["prefix"] + "pvp_arena_" + key + ("_locked" if locked else ""))


def loadout_cards(wd):
    """Each weapon's and Phantom Edge's card: its name in the game's own words, its kind under it."""
    data = open(os.path.join(HERE, "..", "mod", "PBZCoop", "Scripts", "arenas.lua"), encoding="utf-8").read()
    face, p = wd["face"], wd["prefix"]
    for block, kind in (("data.weapons", "main"), ("data.edges", "edge")):
        body = data.split(block + " = {", 1)[1].split("\n}", 1)[0]
        for m in re.finditer(r'id = "(\w+)", name = "([^"]+)", zh = "([^"]+)", kind = "(\w+)"', body):
            wid, en, zh, k = m.groups()
            card(p + "pvp_w_" + wid, en if face is font else zh, wd["kinds"].get(k, ""), face, w=160, h=52,
                 accent=GOLD if kind == "main" else BLOOD)


def page(wd):
    face, p = wd["face"], wd["prefix"]
    page_bg(wd)
    for key, (text, sub) in wd["modes"].items():
        card(p + "pvp_mode_" + key, text, sub, face, accent=BLOOD)
    for key, (text, sub) in wd["clocks"].items():
        card(p + "pvp_clock_" + key, text, sub, face)
    for key, text in wd["slots"].items():
        img, d = canvas(176, 18)
        d.text((2 * K, 9 * K), text, font=face(10), fill=DIM, anchor="lm")
        save(img, p + "pvp_slot_" + key)
    for key, text in wd["buttons"].items():
        button(p + "pvp_" + key, text, face, red=key in ("ready_on", "start"))
    button(p + "pvp_start_off", wd["buttons"]["start"], face, faded=True)
    for team in (1, 2):
        img, d = canvas(96, 24)
        d.rectangle((0, 0, 96 * K, 24 * K), fill=TEAM[team][:3] + (215,))
        frame(d, 96, 24, (230, 230, 230, 180))
        label(d, (48 * K, 12 * K), wd["teams"][team], face, 10, BRIGHT, gap=2, anchor="mm", bold=True)
        save(img, p + "pvp_team_" + str(team))
    arena_cards(wd)
    loadout_cards(wd)


def frames():
    """The bright frame round what's chosen: an arena, a weapon."""
    selected("pvp_sel_arena", 160, 104)
    selected("pvp_sel_weapon", 160, 52)


def player_rows():
    for slot, (rgb, text) in PLAYERS.items():
        img, d = canvas(250, 26)
        d.ellipse((4 * K, 7 * K, 16 * K, 19 * K), fill=rgb + (255,))
        d.text((26 * K, 13 * K), text, font=font(12, True), fill=BRIGHT, anchor="lm")
        save(img, "pvp_row_%d" % slot)
    for on in (0, 1):
        img, d = canvas(26, 26)
        frame(d, 26, 26, FAINT)
        if on:
            d.line((6 * K, 13 * K, 11 * K, 19 * K), fill=(120, 220, 120, 255), width=3 * K)
            d.line((11 * K, 19 * K, 20 * K, 7 * K), fill=(120, 220, 120, 255), width=3 * K)
        save(img, "pvp_tick_%d" % on)


def mate_bars():
    """A teammate's health in a team match, over the player's own bar and in its look (seen on the bench: a dark frame cut
    away at its right end, a bone fill with a grain): the frame, the fill, the blood a blow takes (it drains after), and each
    player's name with their colour, as the lobby's rows have it. Drawn at their size on a screen 1080 high."""
    w, h, cut = 260, 12, 7
    img, d = canvas(w, h)
    d.polygon([(0, 0), (w * K - 1, 0), (w * K - 1 - cut * K, h * K - 1), (0, h * K - 1)], fill=(12, 9, 9, 175),
              outline=(150, 140, 128, 210))
    save_hud(img, "mate_frame")
    fw, fh = 254, 6
    img, d = canvas(fw, fh)
    rng = random.Random(5)
    for x in range(fw * K):
        shade = 214 + int(16 * math.sin(x / (9.0 * K))) + rng.randint(-9, 9)
        d.line((x, 0, x, fh * K), fill=(shade, shade - 5, shade - 13, 255))
    save_hud(img, "mate_fill")
    img, d = canvas(fw, fh)
    d.rectangle((0, 0, fw * K, fh * K), fill=BLOOD)
    save_hud(img, "mate_lag")
    for slot, (rgb, text) in PLAYERS.items():
        for zh in (False, True):
            img, d = canvas(150, 22)
            d.ellipse((2 * K, 7 * K, 10 * K, 15 * K), fill=rgb + (255,))
            if zh:
                d.text((16 * K, 11 * K), "玩家 %d" % slot, font=chinese(12, True), fill=BONE, anchor="lm")
            else:
                spaced(d, (16 * K, 11 * K), text, font(11, True), BONE, gap=2, anchor="lm")
            save_hud(img, ("zh_" if zh else "") + "mate_%d" % slot)


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["fx"]:          # only the effects: everything else redrawn changes its brush strokes' grain
        fx()
        print("PvP effects written to", os.path.normpath(HUD))
        sys.exit(0)
    if sys.argv[1:2] == ["banners"]:    # only these banners (each one's grain comes from its own key: the others stay as they are)
        banners(only=sys.argv[2:] or None)
        print("PvP banners written to", os.path.normpath(HUD))
        sys.exit(0)
    fx()
    banners()
    mate_bars()
    player_rows()
    frames()
    for wd in WORDS.values():
        page(wd)
    print("PvP art written to", os.path.normpath(OUT), "and", os.path.normpath(HUD))
