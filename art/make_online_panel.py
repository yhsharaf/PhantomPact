"""Builds the online panel's pictures (mod/PBZCoop/art/panel) in the local panel's look, in English and in Chinese (zh_*).
Words that change are drawn in the game by the mod. Needs Pillow and Windows' Microsoft YaHei: python art/make_online_panel.py"""
from make_local_panel import *


def chinese(size, bold=False):
    return ImageFont.truetype(FONTS + ("msyhbd.ttc" if bold else "msyh.ttc"), size * K)


WORDS = {
    "en": {
        "prefix": "", "face": font, "title": "ONLINE CO-OP", "status": "STATUS", "through": "CONNECT THROUGH",
        "play": "PLAY", "password": "PASSWORD",
        "help": ["Host: your world, your partner joins you. Guest: you join the host. Leave: back to playing alone.",
                 "Your choice is kept for the next start. Both players use the same way of connecting.",
                 "Steam needs nothing: it finds your friend. The others: copy the host's address, then press Paste.",
                 "Joining takes you to the host, on any map.",
                 "Password: optional. If one player sets it, both must use the same one."],
        "settings": "SETTINGS",
        "rows": [("TP > PARTNER", "on: F3 takes you to your partner, on any map"),
                 ("Revive", "strike a downed partner to bring them back"),
                 ("PvP", "duel your partner; both must turn it on"),
                 ("Partner compass", "shows where your partner is"),
                 ("Partner on the map", "their mark on the game's map"),
                 ("Steam Direct", "less delay, but your partner can see your IP"),
                 ("PLAYERS", "host's choice. 6: ghost twins (test)"),
                 ("Mode", "local: split screen on this PC, from the next start")],
        "soon": "(Coming soon)",
        "foot": ["Kept for next time. Steam Direct and PLAYERS: next connection. Mode: next game start.",
                 "Difficulty is the game's own. With a partner, enemies always get more health."],
        "cards": {"online_steam": ("Steam", "friends, no setup"),
                  "online_tailscale": ("Tailscale", "also Hamachi, Radmin"),
                  "online_other": ("Other network", "ZeroTier, UU..."),
                  "online_paste": ("Paste address", "copied from the host"),
                  "online_password": ("Paste password", "optional, same for both"),
                  "online_password_set": ("Password set", "press to remove")},
        "buttons": {"host": "HOST", "join": "GUEST", "leave": "LEAVE", "settings": "MORE", "back": "BACK"},
        "on": "ON", "off": "OFF", "multiplayer": "MULTIPLAYER", "local": "LOCAL",
    },
    "zh": {
        "prefix": "zh_", "face": chinese, "title": "联机合作", "status": "状态", "through": "连接方式",
        "play": "游玩", "password": "密码",
        "help": ["开房:使用你的世界,队友加入你。加入:你进入房主的世界。离开:回到单人游戏。",
                 "你的选择会保存到下次启动。双方要使用相同的连接方式。",
                 "Steam 无需设置,会自动找到好友。其他方式:复制房主的地址,然后按“粘贴地址”。",
                 "加入后会传送到房主身边,不在同一张地图也可以。",
                 "密码可以不设。一方设置后,双方必须使用相同的密码。"],
        "settings": "设置",
        "rows": [("传送到队友", "开启后按 F3 传送到队友身边,不限地图"),
                 ("复活", "攻击倒地的队友可将其救起"),
                 ("PvP", "与队友决斗,双方都要开启"),
                 ("队友指南针", "显示队友所在的方向"),
                 ("地图上的队友", "在游戏地图上显示队友的位置"),
                 ("Steam 直连", "延迟更低,但队友能看到你的 IP"),
                 ("人数", "房主决定。6 人:幽灵双生(实验)"),
                 ("模式", "本地:同一台电脑分屏,下次启动生效")],
        "soon": "(即将推出)",
        "foot": ["设置会保存。Steam 直连和人数下次连接时生效,模式下次启动游戏时生效。",
                 "难度使用游戏自己的设置。有队友时,敌人总会获得更多生命。"],
        "cards": {"online_steam": ("Steam", "好友联机,无需设置"),
                  "online_tailscale": ("Tailscale", "也适用于 Hamachi、Radmin"),
                  "online_other": ("其他网络", "ZeroTier、UU 加速器"),
                  "online_paste": ("粘贴地址", "从房主那里复制"),
                  "online_password": ("粘贴密码", "可不设,双方必须相同"),
                  "online_password_set": ("密码已设置", "按一下清除")},
        "buttons": {"host": "开房", "join": "加入", "leave": "离开", "settings": "更多", "back": "返回"},
        "on": "开", "off": "关", "multiplayer": "多人联机", "local": "本地分屏",
    },
}


def online_background(w_):
    w, h = 900, 560
    f = w_["face"]
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=BLACK)
    frame(d, w, h, FAINT)
    corners(d, w, h)
    spaced(d, (w * K / 2, 42 * K), w_["title"], f(25), BRIGHT, gap=7)
    d.line(((w / 2 - 170) * K, 67 * K, (w / 2 + 170) * K, 67 * K), fill=FAINT, width=K)
    spaced(d, (40 * K, 96 * K), w_["status"], f(13), DIM, gap=3, anchor="lm")
    d.rectangle((40 * K, 112 * K, 860 * K, 198 * K), fill=(10, 11, 13, 190), outline=FAINT, width=K)
    spaced(d, (40 * K, 226 * K), w_["through"], f(13), DIM, gap=3, anchor="lm")
    spaced(d, (40 * K, 332 * K), w_["play"], f(13), DIM, gap=3, anchor="lm")
    spaced(d, (604 * K, 332 * K), w_["password"], f(13), DIM, gap=3, anchor="lm")
    for y, line in zip((430, 452, 474, 496, 518), w_["help"]):
        d.text((40 * K, y * K), line, font=f(13), fill=DIM, anchor="lm")
    save(img, w_["prefix"] + "online_bg")


def settings_background(w_):
    w, h = 900, 560
    f = w_["face"]
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=BLACK)
    frame(d, w, h, FAINT)
    corners(d, w, h)
    spaced(d, (w * K / 2, 42 * K), w_["settings"], f(25), BRIGHT, gap=7)
    d.line(((w / 2 - 170) * K, 67 * K, (w / 2 + 170) * K, 67 * K), fill=FAINT, width=K)
    for y, (label, sub) in zip((104, 155, 206, 257, 308, 359, 410, 461), w_["rows"]):
        d.text((40 * K, (y - 8) * K), label, font=f(15), fill=BRIGHT, anchor="lm")
        d.text((40 * K, (y + 11) * K), sub, font=f(11), fill=DIM, anchor="lm")
    d.text((300 * K, 155 * K), w_["soon"], font=f(15), fill=DIM, anchor="lm")
    for y, line in zip((505, 528), w_["foot"]):
        d.text((230 * K, y * K), line, font=f(13), fill=DIM, anchor="lm")
    save(img, w_["prefix"] + "online_settings_bg")


def option(name, text, face=font, w=124, h=40):
    img, d = canvas(w, h)
    d.rectangle((0, 0, w * K, h * K), fill=(26, 27, 31, 240))
    frame(d, w, h)
    # A long word closes up, then shrinks, to stay inside the frame. (The short ones never get here.)
    size, gap = 13, 2
    while sum(d.textlength(c, font=face(size)) for c in text) + gap * K * (len(text) - 1) > (w - 14) * K and (gap or size > 9):
        if gap:
            gap -= 1
        else:
            size -= 1
    spaced(d, (w * K / 2, h * K / 2), text, face(size), BRIGHT, gap=gap)
    save(img, name)


def worded(w_):
    """Every picture with words on it, in one language."""
    prefix, face, buttons = w_["prefix"], w_["face"], w_["buttons"]
    online_background(w_)
    settings_background(w_)
    for name, (label, sub) in w_["cards"].items():
        card(prefix + name, label, sub, face)
    button(prefix + "online_host", buttons["host"], face=face)
    button(prefix + "online_join", buttons["join"], face=face)
    button(prefix + "online_host_on", buttons["host"], red=True, face=face)
    button(prefix + "online_join_on", buttons["join"], red=True, face=face)
    button(prefix + "online_leave", buttons["leave"], face=face)
    button(prefix + "online_settings", buttons["settings"], face=face)
    button(prefix + "online_back", buttons["back"], face=face)
    option(prefix + "opt_off", w_["off"], face)
    option(prefix + "opt_on", w_["on"], face)
    option(prefix + "opt_multiplayer", w_["multiplayer"], face)
    option(prefix + "opt_local", w_["local"], face)
    for n in ("2", "4", "6"):
        option(prefix + "opt_" + n, n, font)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    selected("sel_card", 176, 58)
    selected("sel_opt", 124, 40)
    selected("sel_lang", 76, 30)
    option("online_lang_en", "English", font, 76, 30)
    option("online_lang_zh", "中文", chinese, 76, 30)
    worded(WORDS["en"])
    worded(WORDS["zh"])
    print("online panel art written to", os.path.normpath(OUT))
