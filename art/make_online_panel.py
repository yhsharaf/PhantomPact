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
        "tiles": {"teleport": ("TP > Partner", "F3 takes you to your partner, on any map"),
                  "revive": ("Revive", "Strike a downed partner to bring them back"),
                  "pvp": ("PvP", "Duel your partner. Online, the host decides"),
                  "compass": ("Partner Compass", "Shows where your partner is"),
                  "mapicon": ("Partner On The Map", "Their mark on the game's map"),
                  "freetravel": ("Free Bell Travel", "Off: a trip to a bell costs a Traversal Talisman"),
                  "direct": ("Steam Direct", "Less delay, but your partner can see your IP"),
                  "players": ("Players", "Host's choice. 6: ghost twins (test)"),
                  "mode": ("Mode", "Local: split screen on this PC, next start"),
                  "skip": ("Skip Prologue", "New save: the gear and gourd its end gives, then onward"),
                  "skip_ask": ("Skip Prologue", "Click again to skip it. It can't be undone"),
                  "skip_done": ("Skip Prologue", "You're past the prologue")},
        "soon": "SOON",
        "foot": ["Click a tile to change it. Kept for next time. Steam Direct and Players: next connection.",
                 "Mode: next game start. Online, the host decides every tile but Steam Direct and Mode."],
        "cards": {"online_steam": ("Steam", "friends, no setup"),
                  "online_tailscale": ("Tailscale", "also Hamachi, Radmin"),
                  "online_other": ("Other network", "ZeroTier, UU..."),
                  "online_paste": ("Paste address", "copied from the host"),
                  "online_password": ("Paste password", "optional, same for both"),
                  "online_password_set": ("Password set", "press to remove")},
        "buttons": {"host": "HOST", "join": "GUEST", "leave": "LEAVE", "settings": "MORE", "back": "BACK"},
        "on": "ON", "off": "OFF", "multiplayer": "MULTIPLAYER", "local": "LOCAL",
        "skip_words": {"todo": "SKIP", "ask": "SURE?", "done": "DONE"},
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
        "tiles": {"teleport": ("传送到队友", "开启后按 F3 传送到队友身边,不限地图"),
                  "revive": ("复活", "攻击倒地的队友可将其救起"),
                  "pvp": ("PvP", "与队友决斗。联机时由房主决定"),
                  "compass": ("队友指南针", "显示队友所在的方向"),
                  "mapicon": ("地图上的队友", "在游戏地图上显示队友的位置"),
                  "freetravel": ("免费钟传送", "关闭后,传送到钟要消耗道具,与原版相同"),
                  "direct": ("Steam 直连", "延迟更低,但队友能看到你的 IP"),
                  "players": ("人数", "房主决定。6 人:幽灵双生(实验)"),
                  "mode": ("模式", "本地:同一台电脑分屏,下次启动生效"),
                  "skip": ("跳过序章", "新存档:获得序章结束时的装备和葫芦,然后继续"),
                  "skip_ask": ("跳过序章", "再点一次即跳过,无法撤销"),
                  "skip_done": ("跳过序章", "你已经过了序章")},
        "soon": "即将推出",
        "foot": ["点击方块切换。设置会保存。Steam 直连和人数下次连接时生效,",
                 "模式下次启动游戏时生效。联机时,除 Steam 直连和模式外,其他设置都由房主决定。"],
        "cards": {"online_steam": ("Steam", "好友联机,无需设置"),
                  "online_tailscale": ("Tailscale", "也适用于 Hamachi、Radmin"),
                  "online_other": ("其他网络", "ZeroTier、UU 加速器"),
                  "online_paste": ("粘贴地址", "从房主那里复制"),
                  "online_password": ("粘贴密码", "可不设,双方必须相同"),
                  "online_password_set": ("密码已设置", "按一下清除")},
        "buttons": {"host": "开房", "join": "加入", "leave": "离开", "settings": "更多", "back": "返回"},
        "on": "开", "off": "关", "multiplayer": "多人联机", "local": "本地分屏",
        "skip_words": {"todo": "跳过", "ask": "确定?", "done": "已完成"},
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
    for y, line in zip((505, 528), w_["foot"]):
        d.text((230 * K, y * K), line, font=f(12), fill=DIM, anchor="lm")
    save(img, w_["prefix"] + "online_settings_bg")


# The settings as square tiles (the user's design): green and ON with a tick when on, red and OFF with a cross when off,
# gray with the choice for Players and Mode, dim for one still to come. The word and the mark are there for anyone who
# can't tell the red from the green. onlinepanel.lua has the same TILE size and places them.
TILE = 150
LOOKS = {
    "on": ((23, 52, 4, 225), (99, 153, 34, 255), (214, 236, 180, 255), (192, 221, 151, 255)),
    "off": ((80, 19, 19, 225), (163, 45, 45, 255), (252, 214, 214, 255), (247, 193, 193, 255)),
    "multi": ((29, 30, 34, 225), (120, 119, 114, 255), (236, 234, 226, 255), (190, 188, 180, 255)),
    "soon": ((21, 22, 24, 215), (60, 60, 58, 255), (120, 119, 114, 255), (95, 94, 90, 255)),
}


def wrap(d, text, f, width):
    """Lines that fit width: by word, or by character for Chinese."""
    spaced_words = " " in text and not any(ord(c) > 0x2E80 for c in text)
    words = text.split(" ") if spaced_words else list(text)
    joiner = " " if spaced_words else ""
    lines, line = [], ""
    for word in words:
        trial = line + (joiner if line else "") + word
        if line and d.textlength(trial, font=f) > width:
            lines.append(line)
            line = word.lstrip()
        else:
            line = trial
    return lines + [line] if line else lines


def tile(name, label, sub, value, look, face, mark=None):
    fill, edge, title, small = LOOKS[look]
    img, d = canvas(TILE, TILE)
    d.rectangle((0, 0, TILE * K - 1, TILE * K - 1), fill=fill)
    frame(d, TILE, TILE, edge, width=2)
    pad = 12
    y = pad + 2
    for line in wrap(d, label, face(15, True), (TILE - 2 * pad) * K):
        d.text((pad * K, (y + 9) * K), line, font=face(15, True), fill=title, anchor="lm")
        y += 20
    y += 5
    for line in wrap(d, sub, face(11), (TILE - 2 * pad) * K)[:4]:
        d.text((pad * K, (y + 7) * K), line, font=face(11), fill=small, anchor="lm")
        y += 15
    base = TILE - pad - 9
    x = pad
    if mark == "tick":
        d.line(((x + 1) * K, base * K, (x + 6) * K, (base + 5) * K, (x + 15) * K, (base - 6) * K), fill=title,
               width=3 * K, joint="curve")
        x += 22
    elif mark == "cross":
        d.line(((x + 2) * K, (base - 6) * K, (x + 13) * K, (base + 5) * K), fill=title, width=3 * K)
        d.line(((x + 13) * K, (base - 6) * K, (x + 2) * K, (base + 5) * K), fill=title, width=3 * K)
        x += 22
    size, gap = 14, 2
    while size > 9 and sum(d.textlength(c, font=face(size, True)) for c in value) + gap * K * (len(value) - 1) > (TILE - 2 * pad - x + pad) * K:
        gap, size = (gap - 1, size) if gap else (0, size - 1)
    spaced(d, (x * K, base * K), value, face(size, True), title, gap=gap, anchor="lm")
    save(img, name)


def tiles(w_):
    prefix, face, t = w_["prefix"], w_["face"], w_["tiles"]
    for row in ("teleport", "pvp", "compass", "mapicon", "freetravel", "direct"):
        label, sub = t[row]
        tile(prefix + "tile_" + row + "_on", label, sub, w_["on"], "on", face, "tick")
        tile(prefix + "tile_" + row + "_off", label, sub, w_["off"], "off", face, "cross")
    label, sub = t["revive"]
    tile(prefix + "tile_revive_soon", label, sub, w_["soon"], "soon", face)
    label, sub = t["players"]
    for n in ("2", "4", "6"):
        tile(prefix + "tile_players_" + n, label, sub, n, "multi", face)
    label, sub = t["mode"]
    for value in ("multiplayer", "local"):
        tile(prefix + "tile_mode_" + value, label, sub, w_[value], "multi", face)
    # Skip Prologue (the user's design): red in the prologue, red asking once clicked, green for anyone past it.
    sw = w_["skip_words"]
    label, sub = t["skip"]
    tile(prefix + "tile_skip_todo", label, sub, sw["todo"], "off", face, "cross")
    label, sub = t["skip_ask"]
    tile(prefix + "tile_skip_ask", label, sub, sw["ask"], "off", face)
    label, sub = t["skip_done"]
    tile(prefix + "tile_skip_done", label, sub, sw["done"], "on", face, "tick")


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
    tiles(w_)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    selected("sel_card", 176, 58)
    selected("sel_lang", 76, 30)
    option("online_lang_en", "English", font, 76, 30)
    option("online_lang_zh", "中文", chinese, 76, 30)
    worded(WORDS["en"])
    worded(WORDS["zh"])
    print("online panel art written to", os.path.normpath(OUT))
