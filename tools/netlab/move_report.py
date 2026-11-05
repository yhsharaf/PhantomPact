"""How far out of step a partner's moves show on their ghost, from two pair.lua recordings on the clock they share.

  python -I tools/netlab/move_report.py <host recording> <guest recording>

For each montage one side's ghost plays (MG rows), the other side's player's position in the same montage at the same moment
(MP rows) less the ghost's: positive = the ghost shows the move behind. The age each move came with and the round trip (UA
rows) give what the guess before 11-05, half the round trip, would have shown: that, plus the age, less half the round trip.
"""
import bisect
import sys


def load(path):
    rows = {"MP": [], "MG": [], "UA": []}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) >= 4 and p[0] in ("MP", "MG"):
                rows[p[0]].append((float(p[1]), float(p[2]), p[3]))
            elif len(p) >= 4 and p[0] == "UA":
                age = None if p[2] == "nil" else float(p[2])
                rtt = None if p[3] == "nil" else float(p[3])
                rows["UA"].append((float(p[1]), age, rtt))
    return rows


def player_pos(mp, times, t, name):
    """The player's position in the montage at t, if that montage plays on both sides of t without starting over."""
    i = bisect.bisect_right(times, t)
    if i == 0 or i >= len(mp):
        return None
    (t0, p0, n0), (t1, p1, n1) = mp[i - 1], mp[i]
    if n0 != name or n1 != name or p1 < p0 or t1 - t0 > 0.1:
        return None
    return p0 + (p1 - p0) * (t - t0) / (t1 - t0)


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))] if v else float("nan")


def direction(player, watcher, label):
    mp, mg, ua = player["MP"], watcher["MG"], watcher["UA"]
    times = [r[0] for r in mp]
    starts, last = [], None
    for t, g, name in mg:
        if last is None or name != last[2] or g < last[1] - 0.02:
            starts.append([t, name, []])
        last = (t, g, name)
        h = player_pos(mp, times, t, name)
        if h is not None and t - starts[-1][0] <= 0.3:
            starts[-1][2].append((h - g) * 1000)
    now, before = [], []
    for t, _, errors in starts:
        if not errors:
            continue
        e = sorted(errors)[len(errors) // 2]
        now.append(e)
        aged = [u for u in ua if t - 0.2 <= u[0] <= t + 0.02 and u[1] is not None and u[2] is not None]
        if aged:
            _, age, rtt = aged[-1]
            before.append(e + (age - rtt / 2))
    if not now:
        print(f"{label}: no move seen on both sides")
        return
    print(f"{label}: {len(now)} moves seen on both sides")
    off = [abs(x) for x in now]
    print(f"  with its own age:     behind by {sum(now) / len(now):6.1f} ms on average, off by p50 {pct(off, .5):5.1f}  p95 {pct(off, .95):5.1f}  max {max(off):5.1f} ms")
    if before:
        off = [abs(x) for x in before]
        print(f"  half the round trip:  behind by {sum(before) / len(before):6.1f} ms on average, off by p50 {pct(off, .5):5.1f}  p95 {pct(off, .95):5.1f}  max {max(off):5.1f} ms")


host, guest = load(sys.argv[1]), load(sys.argv[2])
direction(host, guest, "the host's moves on the guest's ghost")
direction(guest, host, "the guest's moves on the host's ghost")
