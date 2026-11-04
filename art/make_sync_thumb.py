"""The 1.6.0 "Synchronization Update" thumbnail: the two players in Lei Dang's arena, the online co-op panel
thrown in between them with a glitch echo, sword slashes and ink, and the release lettered on the fog above in
the style of make_art.py (Georgia Bold, gold over ivory, crimson rule).
Re-run:  python -I art/make_sync_thumb.py   ->  art/phantom-pact-1.6.0-thumbnail.png
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from make_art import BOLD, card_text, credit_line, font, red_rule  # noqa: E402

SRC = os.path.join(HERE, "screenshots", "sync-update-1.6.0.png")
PANEL = os.path.join(HERE, "nexus", "guide", "install-4-f5-panel.png")
OUT = os.path.join(HERE, "phantom-pact-1.6.0-thumbnail.png")


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


def make_thumb(src):
    W, H = 1280, 720
    rng = random.Random(160)
    img = src.convert("RGBA").resize((W, H), Image.LANCZOS)
    # Ink and blood behind everything else.
    img = Image.alpha_composite(img, splatter((W, H), rng, 70, (20, 6, 8, 210), [(150, 560), (1150, 520)]))
    img = Image.alpha_composite(img, splatter((W, H), rng, 50, (150, 14, 20, 230), [(230, 640), (1060, 610), (640, 300)]))
    # Two sword strokes across the frame.
    img = Image.alpha_composite(img, slash((W, H), (-40, 600), (1320, 250), 15, (200, 22, 30, 235)))
    img = Image.alpha_composite(img, slash((W, H), (90, 230), (1220, 700), 7, (255, 236, 220, 200)))
    # The panel, thrown in between the two at a slight tilt, with a red/blue echo behind it (the user's pick:
    # "the slight rotate and bigger and glitchy").
    p = panel_image()
    p = p.resize((int(p.width * 0.92), int(p.height * 0.92)), Image.LANCZOS)
    rot = p.rotate(-4, expand=True, resample=Image.BICUBIC)
    px, py = W // 2 - rot.width // 2 + 6, H - rot.height - 10
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 200), (px + 14, py + 18), rot.getchannel("A"))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(14)))
    for off, tint in (((-12, -4), (255, 30, 50)), ((12, 5), (40, 200, 255))):
        echo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        mask = rot.getchannel("A").point(lambda v: int(v * 0.42))
        echo.paste(tint + (255,), (px + off[0], py + off[1]), mask)
        img = Image.alpha_composite(img, echo)
    img.alpha_composite(rot, (px, py))
    # A thin cut through the panel itself, and the glitch over everything.
    img = Image.alpha_composite(img, slash((W, H), (380, 715), (920, 370), 4, (255, 60, 60, 220)))
    # (Clear of the panel's heading, its HOST / GUEST / LEAVE row and MORE: the user wanted those readable.)
    img = glitch_bands(img, rng, 9, keep=((325, 385), (525, 600), (645, 705)))
    # A soft darkening at the top, so the lettering reads on the bright fog.
    shade = Image.new("L", (1, H))
    for y in range(H):
        shade.putpixel((0, y), int(150 * max(0.0, 1 - y / (H * 0.45)) ** 1.5))
    dark = Image.new("RGBA", (W, H), (14, 6, 8, 255))
    dark.putalpha(shade.resize((W, H)))
    img = Image.alpha_composite(img, dark)
    cx = W / 2
    items = [
        (cx, 26, "PHANTOM PACT  •  1.6.0", font(BOLD, 40), 3, "gold"),
        (cx, 98, "SYNCHRONIZATION", font(BOLD, 74), 3, "hero"),
        (cx, 182, "UPDATE", font(BOLD, 74), 6, "hero"),
    ]
    img = Image.alpha_composite(img, card_text((W, H), items))
    img = red_rule(img, cx - 230, cx + 230, 84, 3)
    credit_line(img, "Fan-made mod for Phantom Blade Zero", 18, (W - 16, H - 30), align="right")
    return img.convert("RGB")


def main():
    src = Image.open(SRC)
    src.load()
    make_thumb(src).save(OUT, optimize=True)
    print(OUT)


if __name__ == "__main__":
    main()
