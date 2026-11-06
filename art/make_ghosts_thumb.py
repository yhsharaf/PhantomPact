"""The 1.6.5 "Ghosts Update" thumbnail, in the 1.6.0 one's design (the user's pick): six players seen low from behind,
facing Peng Meng and his cyan ghost twin under two boss bars, the online co-op panel thrown in at the bottom left with
a red/cyan glitch echo, sword slashes and ink, and the release lettered above in the style of make_art.py.
Re-run:  python -I art/make_ghosts_thumb.py   ->  art/thumbnail/PhantomPact-1.6.5-thumbnail.png
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from make_art import BOLD, card_text, credit_line, font, red_rule  # noqa: E402

SRC = os.path.join(HERE, "screenshots", "ghosts-update-1.7.0.png")
PANEL = os.path.join(HERE, "nexus", "guide", "install-4-f5-panel.png")
OUT = os.path.join(HERE, "thumbnail", "PhantomPact-1.6.5-thumbnail.png")


def panel_image():
    """The F5 panel from the install guide, its caption cut off. Its status line had the partner's name blanked:
    a status without anyone's name is written over it."""
    p = Image.open(PANEL).convert("RGBA").crop((10, 66, 650, 456))
    d = ImageDraw.Draw(p)
    d.rectangle([40, 82, 600, 128], fill=(14, 14, 16, 255))
    f = ImageFont.truetype(r"C:\Windows\Fonts\segoeui.ttf", 15)
    s = "Connected.  Ping 4 ms.  Route: direct."
    d.text((320 - d.textlength(s, font=f) / 2, 96), s, font=f, fill=(236, 236, 236, 255))
    return p


def slash(size, p0, p1, width, color):
    """A sword stroke: thick in the middle, sharp at both ends, with a soft glow."""
    W, H = size
    lay = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    n = math.hypot(dx, dy)
    nx, ny = -dy / n, dx / n
    pts_top, pts_bot = [], []
    for i in range(41):
        t = i / 40
        w = width * math.sin(math.pi * t) ** 0.8
        x, y = x0 + dx * t, y0 + dy * t
        pts_top.append((x + nx * w, y + ny * w))
        pts_bot.append((x - nx * w * 0.35, y - ny * w * 0.35))
    d.polygon(pts_top + pts_bot[::-1], fill=color)
    glow = lay.filter(ImageFilter.GaussianBlur(width * 1.4))
    return Image.alpha_composite(glow, lay)


def splatter(size, rng, n, color, spread):
    lay = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for cx, cy in spread:
        for _ in range(n):
            a = rng.uniform(0, math.tau)
            r = rng.expovariate(1 / 70)
            x, y = cx + math.cos(a) * r, cy + math.sin(a) * r * 0.7
            s = min(7.0, max(1.0, rng.expovariate(1 / 2.6) * (1.3 if r < 40 else 0.6)))
            d.ellipse([x - s, y - s, x + s, y + s], fill=color)
    return lay.filter(ImageFilter.GaussianBlur(0.6))


def glitch_bands(img, rng, count, keep=()):
    """count bands of the picture shifted sideways; none crosses a y range in keep (the panel's heading and
    buttons stay readable)."""
    W, H = img.size
    out = img.copy()
    placed = 0
    while placed < count:
        y = rng.randint(int(H * 0.3), H - 20)
        h = rng.randint(3, 14)
        if any(y < b and y + h > a for a, b in keep):
            continue
        placed += 1
        dx = rng.randint(-26, 26)
        band = img.crop((0, y, W, y + h))
        out.paste(band, (dx, y))
    return out

# The six players, traced by hand on the 960x540 shot (left to right). Each gets its own colour: a soft halo just
# outside the outline and its body lifted out of the dark (the user: "the players to be more clear").
PLAYERS = [
    ((255, 196, 70), [(0, 410), (25, 405), (45, 400), (65, 405), (75, 418), (78, 433), (60, 440), (50, 455), (55, 480),
                      (50, 510), (45, 540), (0, 540)]),
    ((120, 170, 255), [(112, 455), (122, 440), (130, 422), (145, 410), (160, 410), (180, 418), (200, 430), (208, 450),
                       (200, 470), (185, 485), (165, 492), (140, 500), (120, 505), (108, 485)]),
    ((255, 80, 70), [(288, 370), (300, 368), (312, 378), (330, 382), (332, 392), (318, 400), (320, 420), (330, 440),
                     (320, 460), (305, 470), (300, 490), (270, 490), (255, 470), (248, 450), (258, 420), (272, 395),
                     (282, 380)]),
    ((190, 120, 255), [(655, 358), (670, 356), (675, 368), (690, 372), (686, 395), (685, 420), (700, 440), (705, 455),
                       (690, 465), (700, 490), (680, 495), (665, 470), (655, 500), (645, 500), (640, 470), (625, 465),
                       (628, 430), (640, 410), (650, 390), (652, 370)]),
    ((90, 230, 120), [(795, 362), (812, 364), (815, 378), (840, 390), (840, 405), (830, 420), (845, 440), (850, 470),
                      (848, 505), (830, 505), (820, 470), (805, 470), (800, 490), (760, 495), (730, 490), (715, 470),
                      (718, 450), (735, 435), (750, 420), (748, 400), (760, 385), (790, 380)]),
    ((255, 150, 50), [(930, 445), (945, 436), (960, 430), (960, 505), (935, 505), (925, 480)]),
]


def light_players(img):
    W, H = img.size
    k = W / 960
    for color, poly in PLAYERS:
        pts = [(x * k, y * k) for x, y in poly]
        m = Image.new("L", (W, H), 0)
        ImageDraw.Draw(m).polygon(pts, fill=255)
        inner = m.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.GaussianBlur(6))
        # Lift the body out of the dark (their own outfit still showing), with a faint touch of the colour.
        rgb = img.convert("RGB")
        lift = rgb.point(lambda v: min(255, int(18 + v * 1.7)))
        lift = ImageChops.screen(lift, Image.new("RGB", (W, H), tuple(int(c * 0.10) for c in color))).convert("RGBA")
        img = Image.composite(lift, img, inner)
        # A soft aura in the player's colour, and a rim light along the real edges of their armour and cloak
        # near the outline (the trace is by hand: a line along it would show its corners).
        aura = m.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(22)).point(lambda v: int(v * 0.5))
        img = Image.composite(ImageChops.screen(img.convert("RGB"), Image.new("RGB", (W, H), color)).convert("RGBA"),
                              img, aura)
        band = ImageChops.subtract(m.filter(ImageFilter.MaxFilter(7)), m.filter(ImageFilter.MinFilter(21)))
        band = band.filter(ImageFilter.GaussianBlur(3))
        edges = rgb.convert("L").filter(ImageFilter.GaussianBlur(0.8)).filter(ImageFilter.FIND_EDGES)
        edges = edges.point(lambda v: min(255, max(0, (v - 6) * 9)))
        rim = ImageChops.multiply(edges, band)
        for blur, alpha in ((5, 0.8), (0.8, 1.0)):
            g = rim.filter(ImageFilter.GaussianBlur(blur)).point(lambda v, a=alpha: min(255, int(v * a * 2.2)))
            glow = Image.new("RGB", (W, H), tuple(min(255, c + 60) for c in color))
            img = Image.composite(ImageChops.screen(img.convert("RGB"), glow).convert("RGBA"), img, g)
    return img


def make_thumb(src):
    W, H = 1280, 720
    rng = random.Random(170)
    img = src.convert("RGBA").resize((W, H), Image.LANCZOS)
    img = light_players(img)
    # Ink and blood behind everything else.
    img = Image.alpha_composite(img, splatter((W, H), rng, 70, (20, 6, 8, 210), [(120, 600), (1180, 560)]))
    img = Image.alpha_composite(img, splatter((W, H), rng, 50, (150, 14, 20, 230), [(330, 680), (1080, 640), (980, 300)]))
    # Two sword strokes across the frame.
    # (Kept off the two bosses in the middle: the strokes run low on the right and through the sky.)
    img = Image.alpha_composite(img, slash((W, H), (430, 735), (1320, 560), 15, (200, 22, 30, 235)))
    img = Image.alpha_composite(img, slash((W, H), (860, 300), (1300, 150), 7, (255, 236, 220, 200)))
    # The panel, thrown in between the two at a slight tilt, with a red/blue echo behind it (the user's pick:
    # "the slight rotate and bigger and glitchy").
    p = panel_image()
    # (Up in the trees on the left, small: lower down it hid the heroes on the left, and all six are the point.)
    p = p.resize((int(p.width * 0.5), int(p.height * 0.5)), Image.LANCZOS)
    rot = p.rotate(-4, expand=True, resample=Image.BICUBIC)
    px, py = 16, 300
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 200), (px + 14, py + 18), rot.getchannel("A"))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(14)))
    for off, tint in (((-10, -4), (255, 30, 50)), ((10, 5), (60, 240, 255))):
        echo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        mask = rot.getchannel("A").point(lambda v: int(v * 0.42))
        echo.paste(tint + (255,), (px + off[0], py + off[1]), mask)
        img = Image.alpha_composite(img, echo)
    img.alpha_composite(rot, (px, py))
    # A thin cut through the panel itself, and the glitch over everything.
    img = Image.alpha_composite(img, slash((W, H), (10, 470), (360, 250), 4, (255, 60, 60, 220)))
    # (Clear of the panel's heading and its HOST / GUEST / LEAVE row, and of the heroes and bosses below.)
    img = glitch_bands(img, rng, 9, keep=((240, 720),))
    # A soft darkening at the top, so the lettering reads on the bright fog.
    # (Not over the game's two boss bars and their five marks at the very top: the user wants those seen.)
    shade = Image.new("L", (1, H))
    for y in range(H):
        f = 0.0 if y < 70 else min(1.0, (y - 70) / 40) * max(0.0, 1 - (y - 110) / (H * 0.42)) ** 1.3
        shade.putpixel((0, y), int(140 * min(1.0, f)))
    dark = Image.new("RGBA", (W, H), (14, 6, 8, 255))
    dark.putalpha(shade.resize((W, H)))
    img = Image.alpha_composite(img, dark)
    cx = W / 2
    items = [
        # (Below the boss bars, which end about y 72.)
        (cx, 84, "PHANTOM PACT  •  1.6.5", font(BOLD, 36), 3, "gold"),
        (cx, 148, "GHOSTS UPDATE", font(BOLD, 80), 3, "hero"),
        (cx, 240, "5-6 PLAYERS CO-OP", font(BOLD, 50), 4, "gold"),
    ]
    img = Image.alpha_composite(img, card_text((W, H), items))
    img = red_rule(img, cx - 210, cx + 210, 136, 3)
    credit_line(img, "Fan-made mod for Phantom Blade Zero", 18, (W - 16, H - 30), align="right")
    return img.convert("RGB")


def main():
    src = Image.open(SRC)
    src.load()
    make_thumb(src).save(OUT, optimize=True)
    print(OUT)


if __name__ == "__main__":
    main()
