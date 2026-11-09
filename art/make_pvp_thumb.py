"""The 1.7.0 "PvP Update" thumbnail, in the 1.6.0 and 1.6.5 ones' design (the user, 11-09: "keep consistent to 1.6.5"):
a duel in the Crimson Forest, YuCong's snowfield under its chains and lanterns: one player leaping in from the right with
the blade raised, the other braced below on the left, the foe's bar over them as a match shows it, the F6 page thrown in
between them with a red/cyan glitch echo (as 1.6.0's panel in the middle), sword slashes and ink, and the release
lettered above in the style of make_art.py. The whole picture graded first (the user: "give shader to the whole
environment"): contrast, teal shadows and warm highlights, the lanterns and the blade glowing, a vignette, falling snow.
The shot is the game's own screen at 1920 x 1080 on the bench, the world held still mid-leap and seen from a camera of
ours (screenshots/pvp-update-1.7.0.png, kept out of git like the others; the page from the F6 page on the bench).
Re-run:  python -I art/make_pvp_thumb.py   ->  art/thumbnail/PhantomPact-1.7.0-thumbnail.png (and -1920)
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from make_art import BOLD, card_text, credit_line, font, red_rule  # noqa: E402
from make_ghosts_thumb import glitch_bands, slash  # noqa: E402

SHOTS = os.path.join(HERE, "screenshots")
SRC = os.path.join(SHOTS, "pvp-update-1.7.0.png")           # the game's screen, the foe's bar on it
PAGE = os.path.join(SHOTS, "pvp-update-1.7.0-page.png")     # the F6 page ("Waiting for player 2 (green) to be ready.")
OUT = os.path.join(HERE, "thumbnail", "PhantomPact-1.7.0-thumbnail{}.png")
SHADE = 150             # the dark pool behind the lettering at its middle (of 255)


def grade(img):
    """The film grade over the whole shot: an S curve, teal shadows and warm highlights, the warm lights (lanterns, the
    blade's red edge) blooming, the corners darker."""
    a = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    lum = a @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    s = a * a * (3 - 2 * a)
    a = a + (s - a) * 0.35
    shadow = np.clip(1 - lum / 0.55, 0, 1)[..., None]
    light = np.clip((lum - 0.45) / 0.55, 0, 1)[..., None]
    a = a * (1 + shadow * np.array([-0.10, 0.0, 0.07], dtype=np.float32) + light * np.array([0.05, 0.0, -0.06], dtype=np.float32))
    a = a * 0.97
    # The warm lights only: red well over blue, and bright.
    warm = np.clip((a[..., 0] - a[..., 2] - 0.18) * 3.0, 0, 1) * np.clip((lum - 0.35) * 2.0, 0, 1)
    w = Image.fromarray((warm * 255).astype(np.uint8))
    H, W = warm.shape
    glow = np.zeros_like(a)
    for r, k in ((W * 0.006, 0.9), (W * 0.02, 0.6), (W * 0.05, 0.35)):
        g = np.asarray(w.filter(ImageFilter.GaussianBlur(r)), dtype=np.float32) / 255.0
        glow += g[..., None] * k
    a = 1 - (1 - a) * (1 - np.clip(glow * np.array([1.0, 0.55, 0.22], dtype=np.float32), 0, 1))
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.sqrt(((xx - W * 0.52) / (W * 0.66)) ** 2 + ((yy - H * 0.55) / (H * 0.72)) ** 2)
    a = a * (1 - 0.32 * np.clip(d - 0.55, 0, 1) ** 1.4)[..., None]
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).convert("RGBA")


def snow(size, rng, k):
    """Snow falling across the frame: fine flakes, a few big soft ones near the lens."""
    W, H = size
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    for n, rmin, rmax, alpha, blur in ((220, 0.8, 1.8, 200, 0.4), (60, 2.2, 3.6, 150, 1.2), (10, 7, 13, 70, 5)):
        lay = Image.new("RGBA", size, (0, 0, 0, 0))
        d = ImageDraw.Draw(lay)
        for _ in range(n):
            x, y = rng.uniform(0, W), rng.uniform(0, H)
            r = rng.uniform(rmin, rmax) * k
            d.ellipse([x - r, y - r * 1.4, x + r, y + r * 1.4], fill=(236, 242, 246, int(alpha * rng.uniform(0.5, 1))))
        out = Image.alpha_composite(out, lay.filter(ImageFilter.GaussianBlur(blur * k)))
    return out


def splatter(size, rng, n, color, spread, k):
    """make_ghosts_thumb.py's ink, its drops k times the size (the same look at 1920 wide)."""
    lay = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for cx, cy in spread:
        for _ in range(n):
            a = rng.uniform(0, math.tau)
            r = rng.expovariate(1 / 70) * k
            x, y = cx + math.cos(a) * r, cy + math.sin(a) * r * 0.7
            s = min(7.0, max(1.0, rng.expovariate(1 / 2.6) * (1.3 if r < 40 * k else 0.6))) * k
            d.ellipse([x - s, y - s, x + s, y + s], fill=color)
    return lay.filter(ImageFilter.GaussianBlur(0.6 * k))


def make_thumb(W):
    H = W * 9 // 16
    k = W / 1280
    rng = random.Random(170)
    img = grade(Image.open(SRC).convert("RGB").resize((W, H), Image.LANCZOS))
    img = Image.alpha_composite(img, snow((W, H), rng, k))
    img = img.filter(ImageFilter.UnsharpMask(radius=1.6 * k, percent=55, threshold=2))
    # Ink and blood behind everything else.
    img = Image.alpha_composite(img, splatter((W, H), rng, 70, (20, 6, 8, 210), [(120 * k, 650 * k), (1190 * k, 640 * k)], k))
    img = Image.alpha_composite(img, splatter((W, H), rng, 50, (150, 14, 20, 230),
                                              [(340 * k, 700 * k), (1060 * k, 690 * k), (930 * k, 610 * k)], k))
    # Two sword strokes across the frame, kept off the two players: low across the snow, and through the trees above the
    # braced one.
    img = Image.alpha_composite(img, slash((W, H), (560 * k, 742 * k), (1320 * k, 630 * k), 15 * k, (200, 22, 30, 235)))
    img = Image.alpha_composite(img, slash((W, H), (40 * k, 360 * k), (430 * k, 200 * k), 7 * k, (255, 236, 220, 200)))
    # The F6 page, thrown in between the two at a slight tilt, with a red/blue echo behind it.
    p = Image.open(PAGE).convert("RGBA")
    p = p.resize((int(p.width * 0.62 * k), int(p.height * 0.62 * k)), Image.LANCZOS)
    rot = p.rotate(-3, expand=True, resample=Image.BICUBIC)
    px, py = int(W / 2 - rot.width / 2 - 10 * k), int(338 * k)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 200), (px + int(14 * k), py + int(18 * k)), rot.getchannel("A"))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(14 * k)))
    for off, tint in (((-10, -4), (255, 30, 50)), ((10, 5), (60, 240, 255))):
        echo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        mask = rot.getchannel("A").point(lambda v: int(v * 0.42))
        echo.paste(tint + (255,), (px + int(off[0] * k), py + int(off[1] * k)), mask)
        img = Image.alpha_composite(img, echo)
    img.alpha_composite(rot, (px, py))
    # A thin cut through the page itself, and the glitch over everything (clear of the page, the players and the bar).
    img = Image.alpha_composite(img, slash((W, H), (px + 20 * k, py + rot.height - 30 * k),
                                           (px + rot.width - 20 * k, py + 40 * k), 4 * k, (255, 60, 60, 220)))
    img = glitch_bands(img, rng, 9, keep=((262 * k, H),))
    # A soft dark pool behind the lettering alone, so it reads on the bright fog: an ellipse round the title, blurred wide.
    # (1.6.5's band across the whole width, on this bright snow, read as a black strip edge to edge; the user: "the black
    # thing is stretching fully".)
    pool = Image.new("L", (W // 4, H // 4), 0)
    cx4, cy4, rx, ry = W / 8, 212 * k / 4, 470 * k / 4, 118 * k / 4
    ImageDraw.Draw(pool).ellipse((cx4 - rx, cy4 - ry, cx4 + rx, cy4 + ry), fill=SHADE)
    pool = pool.filter(ImageFilter.GaussianBlur(34 * k / 4)).resize((W, H), Image.BILINEAR)
    dark = Image.new("RGBA", (W, H), (14, 6, 8, 255))
    dark.putalpha(pool)
    img = Image.alpha_composite(img, dark)
    cx = W / 2
    # (Below the foe's bar and its name line, which end about y 96.)
    items = [
        (cx, 106 * k, "PHANTOM PACT  •  1.7.0", font(BOLD, round(36 * k)), 3 * k, "gold"),
        (cx, 170 * k, "PVP UPDATE", font(BOLD, round(80 * k)), 3 * k, "hero"),
        (cx, 262 * k, "DUELS IN BOSS ARENAS", font(BOLD, round(50 * k)), 4 * k, "gold"),
    ]
    img = Image.alpha_composite(img, card_text((W, H), items))
    img = red_rule(img, cx - 210 * k, cx + 210 * k, 158 * k, 3 * k)
    credit_line(img, "Fan-made mod for Phantom Blade Zero", round(18 * k), (W - 16 * k, H - 30 * k), align="right")
    return img.convert("RGB")


def main():
    for W, tail in ((1280, ""), (1920, "-1920")):
        out = OUT.format(tail)
        make_thumb(W).save(out, optimize=True)
        print(out)


if __name__ == "__main__":
    main()
