"""Builds the revive gauge's frames (mod/PBZCoop/art/revive) from the Lumina ring art. The game can't draw a smooth
ring by itself, so each state is a picture: g<bars>_<step>.png for the jade bars, t<step>.png for the timer around them.
Needs Pillow: python art/make_revive_ring.py"""
import os
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "mod", "PBZCoop", "art", "revive")
SIZE = 128
K = 3
GAP = 5
STEPS_PER_BAR = 12
TIMER_STEPS = 24

raw = Image.open(os.path.join(HERE, "lumina-revive-ring-original.png")).convert("RGB")
box = ImageOps.grayscale(raw).point(lambda v: 255 if v > 30 else 0).getbbox()
crop = raw.crop(box).resize((512, 512), Image.LANCZOS)
alpha = ImageOps.grayscale(crop).point(lambda v: 0 if v < 26 else min(255, int((v - 26) * 3)))
ring = crop.convert("RGBA")
ring.putalpha(alpha)
inner = int(SIZE * .84)
base = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
base.paste(ring.resize((inner, inner), Image.LANCZOS), ((SIZE - inner) // 2, (SIZE - inner) // 2))
jade = ImageEnhance.Brightness(ImageEnhance.Color(base).enhance(1.5)).enhance(1.25)
jade.putalpha(base.getchannel("A"))


def wedge(a0, a1):
    m = Image.new("L", (SIZE * K, SIZE * K), 0)
    ImageDraw.Draw(m).pieslice([0, 0, SIZE * K - 1, SIZE * K - 1], a0 - 90, a1 - 90, fill=255)
    return m.resize((SIZE, SIZE), Image.LANCZOS)


def backing():
    """The ink wash and the ghost of the empty ring, so it reads on bamboo or snow alike."""
    w = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(w).ellipse([SIZE * .05, SIZE * .05, SIZE * .95, SIZE * .95], fill=150)
    wash = Image.new("RGBA", (SIZE, SIZE), (8, 10, 9, 0))
    wash.putalpha(w.filter(ImageFilter.GaussianBlur(SIZE / 16)))
    dim = ImageEnhance.Brightness(base).enhance(0.45)
    dim.putalpha(base.getchannel("A").point(lambda v: int(v * .22)))
    wash.alpha_composite(dim)
    return wash


def gauge(bars, frac):
    out = backing()
    lit = Image.new("L", (SIZE, SIZE), 0)
    left = bars * 120 * frac
    for i in range(bars):
        s0 = i * 120
        if left > s0:
            lit.paste(255, (0, 0), wedge(s0 + GAP, min(s0 + 120 - GAP, s0 + GAP + left - s0)))
    layer = jade.copy()
    layer.putalpha(Image.composite(jade.getchannel("A"), Image.new("L", (SIZE, SIZE), 0), lit))
    out.alpha_composite(layer.filter(ImageFilter.GaussianBlur(SIZE / 60)))
    out.alpha_composite(layer)
    return out


def timer(frac):
    t = Image.new("RGBA", (SIZE * K, SIZE * K), (0, 0, 0, 0))
    c = int(SIZE * K * .02)
    ImageDraw.Draw(t).arc([c, c, SIZE * K - c, SIZE * K - c], -90, -90 + 360 * frac, fill=(214, 226, 218, 230),
                          width=int(SIZE * K * .016))
    return t.resize((SIZE, SIZE), Image.LANCZOS)


os.makedirs(OUT, exist_ok=True)
for bars in (1, 2, 3):
    for step in range(STEPS_PER_BAR * bars + 1):
        gauge(bars, step / (STEPS_PER_BAR * bars)).save(os.path.join(OUT, f"g{bars}_{step}.png"), optimize=True)
for step in range(TIMER_STEPS + 1):
    timer(step / TIMER_STEPS).save(os.path.join(OUT, f"t{step}.png"), optimize=True)
