"""Builds the local co-op panel's pictures (mod/PBZCoop/art/panel): see-through black, thin silver lines, all text baked
in, because the mod draws with the game's one-image widget. Needs Pillow: python art/make_local_panel.py"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "mod", "PBZCoop", "art", "panel")
FONTS = "C:/Windows/Fonts/"
K = 3                       # drawn this much bigger, then shrunk, for clean edges
SILVER = (206, 210, 216, 255)
DIM = (150, 154, 160, 255)
FAINT = (206, 210, 216, 90)
BLACK = (6, 7, 9, 205)
CELL = (14, 15, 18, 215)
BRIGHT = (255, 255, 255, 255)


def font(size, bold=False):
    return ImageFont.truetype(FONTS + ("georgiab.ttf" if bold else "georgia.ttf"), size * K)


def canvas(w, h):
    img = Image.new("RGBA", (w * K, h * K), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def save(img, name):
    w, h = img.size
    img.resize((w // K, h // K), Image.LANCZOS).save(os.path.join(OUT, name + ".png"))


def spaced(d, xy, text, f, fill, gap=0, anchor="mm"):
    """Text with letter spacing, centred on xy (or starting there with anchor "lm")."""
    total = sum(d.textlength(c, font=f) for c in text) + gap * K * (len(text) - 1)
    x = xy[0] - total / 2 if anchor == "mm" else xy[0]
    for c in text:
        d.text((x, xy[1]), c, font=f, fill=fill, anchor="lm")
        x += d.textlength(c, font=f) + gap * K


def frame(d, w, h, line=SILVER, inset=1, width=1):
    i = inset * K
    d.rectangle((i, i, w * K - 1 - i, h * K - 1 - i), outline=line, width=width * K)


def corners(d, w, h, size=14, inset=7):
    """The little silver corner marks of the game's own menus."""
    i, s, W, H = inset * K, size * K, w * K - 1, h * K - 1
    for a, b in ((i, i), (W - i, i), (i, H - i), (W - i, H - i)):
        dx = s if a == i else -s
        dy = s if b == i else -s
        d.line((a, b, a + dx, b), fill=SILVER, width=K)
        d.line((a, b, a, b + dy), fill=SILVER, width=K)


def ground(rule=True):
    """A page with no words on it: see-through black, the frame, the corners and the rule under the title. (Each picture
    here is drawn as its ground, then its words, so the Arabic ones can share the ground: make_arabic_art.py.)"""
    w, h = 900, 560
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=BLACK)
    frame(d, w, h, FAINT)
    corners(d, w, h)
    if rule:
        d.line(((w / 2 - 170) * K, 67 * K, (w / 2 + 170) * K, 67 * K), fill=FAINT, width=K)
    return img, d


def background():
    w, h = 900, 560
    img, d = ground()
    spaced(d, (w * K / 2, 42 * K), "LOCAL CO-OP", font(25), BRIGHT, gap=7)
    spaced(d, (40 * K, 96 * K), "PLAYERS", font(13), DIM, gap=3, anchor="lm")
    spaced(d, (480 * K, 96 * K), "SCREEN", font(13), DIM, gap=3, anchor="lm")
    spaced(d, (40 * K, 214 * K), "CONTROLS", font(13), DIM, gap=3, anchor="lm")
    d.text((230 * K, 505 * K), "Hold any button on a joystick to light up its card.", font=font(13), fill=DIM, anchor="lm")
    d.text((230 * K, 528 * K), "Drag cards onto players.", font=font(13), fill=DIM, anchor="lm")
    save(img, "bg")


def close():
    img, d = canvas(38, 38)
    frame(d, 38, 38, FAINT)
    m = 12 * K
    W = 38 * K - 1
    d.line((m, m, W - m, W - m), fill=SILVER, width=2 * K)
    d.line((W - m, m, m, W - m), fill=SILVER, width=2 * K)
    save(img, "close")


def tab(n):
    img, d = canvas(64, 64)
    d.rectangle((0, 0, 64 * K, 64 * K), fill=CELL)
    frame(d, 64, 64)
    spaced(d, (32 * K, 32 * K), str(n), font(27), BRIGHT)
    save(img, "tab%d" % n)


def thumb(name, cells):
    """A small screen picture: cells are (x0, y0, x1, y1) in 0..1, one for each player."""
    w, h = 118, 70
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=CELL)
    pad = 6 * K
    W, H = w * K - 2 * pad, h * K - 2 * pad
    for i, (x0, y0, x1, y1) in enumerate(cells):
        box = (pad + x0 * W + K, pad + y0 * H + K, pad + x1 * W - K, pad + y1 * H - K)
        d.rectangle(box, fill=(46, 48, 53, 255), outline=SILVER, width=K)
        d.text(((box[0] + box[2]) / 2, (box[1] + box[3]) / 2), str(i + 1), font=font(14), fill=BRIGHT, anchor="mm")
    frame(d, w, h, FAINT)
    save(img, name)


def selected(name, w, h):
    img, d = canvas(w, h)
    frame(d, w, h, BRIGHT, inset=0, width=2)
    corners(d, w, h, size=9, inset=4)
    save(img, name)


def box(w, h):
    """A dark box in a silver frame, with no words: a card's or an option's ground."""
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(26, 27, 31, 240))
    frame(d, w, h)
    return img, d


def card(name, label, sub, face=font):
    img, d = box(176, 58)
    d.text((14 * K, 22 * K), label, font=face(15), fill=BRIGHT, anchor="lm")
    d.text((14 * K, 42 * K), sub, font=face(11), fill=DIM, anchor="lm")
    save(img, name)


def slot(n):
    w, h = 196, 78
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(10, 11, 13, 190))
    frame(d, w, h, FAINT)
    corners(d, w, h, size=8, inset=4)
    spaced(d, (98 * K, 10 * K), "PLAYER %d" % n, font(10), DIM, gap=2)
    save(img, "slot%d" % n)


def hold():
    """The bar that fills under a joystick's card while a button is held."""
    w, h, steps = 176, 6, 8
    for i in range(steps + 1):
        img, d = canvas(w, h)
        d.rectangle((0, 0, w * K, h * K), fill=(0, 0, 0, 170))
        d.rectangle((0, 0, w * K * i // steps, h * K), fill=BRIGHT)
        save(img, "hold%d" % i)


def button_ground(red=False):
    """A button with no words, and the colour its words go in: light with dark words, or red with white ones."""
    w, h = 170, 46
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(150, 26, 22, 235) if red else (214, 217, 222, 235))
    return img, d, BRIGHT if red else (10, 11, 13, 255)


def button(name, text, red=False, face=font, gap=3):
    w, h = 170, 46
    img, d, ink = button_ground(red)
    spaced(d, (w * K / 2, h * K / 2), text, face(16, True), ink, gap=gap)
    save(img, name)


def health_bar():
    """Player 2's health: the game draws its own bar for player 1 only."""
    w, h = 300, 16
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(6, 7, 9, 170))
    frame(d, w, h, SILVER, inset=0)
    save(img, "bar_frame")
    w, h = 296, 12
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(226, 228, 232, 255))
    save(img, "bar_fill")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    health_bar()
    background()
    close()
    for n in (1, 2, 3, 4):
        tab(n)
    for n in (1, 2, 3, 4):
        slot(n)
    thumb("layout_tb", [(0, 0, 1, .5), (0, .5, 1, 1)])
    thumb("layout_lr", [(0, 0, .5, 1), (.5, 0, 1, 1)])
    thumb("layout_3top", [(0, 0, 1, .5), (0, .5, .5, 1), (.5, .5, 1, 1)])
    thumb("layout_3bottom", [(0, 0, .5, .5), (.5, 0, 1, .5), (0, .5, 1, 1)])
    thumb("layout_4", [(0, 0, .5, .5), (.5, 0, 1, .5), (0, .5, .5, 1), (.5, .5, 1, 1)])
    selected("sel_tab", 64, 64)
    selected("sel_layout", 118, 70)
    card("card_kbm", "Keyboard & Mouse", "one per game")
    for n in (1, 2, 3, 4):
        card("card_joy%d" % n, "Joystick %d" % n, "connected")
    hold()
    button("apply", "APPLY")
    button("applied", "APPLIED", red=True)
    button("multiplayer", "MULTIPLAYER", gap=1)
    print("panel art written to", os.path.normpath(OUT))
