// Two monitors for local co-op (Monitors = 2 in PhantomPact.ini, or the F4 panel's two-monitor picture). The game's one
// window is spread over the monitor it's on and the one beside it (or above or below it), with no border, and the engine's
// own split then puts each player's half on a monitor of their own. Plain Windows calls on the game's window: nothing of
// the game's code or memory is touched, so a game update can't break it.
//   screens.txt      written by the mod: "two" spreads the window, "one" puts it back as the game had it. Removed at start:
//                    a run that crashed while spread must not spread the next one's title screen
//   screens_out.txt  written here, one line, when it changes: "<state> <split> <w> <h> <mw> <mh> <why>"
//                      state  two (spread now), one (as the game had it), none (two is wanted and can't be had)
//                      split  lr (side by side) or tb (one above the other), the engine's split for the pair; - if none
//                      w h    the spread window's size; mw mh  each player's half, one monitor's worth
//                      why    ok, or for none: single (no monitor beside this one), nowindow, fight (the window was taken
//                             back again and again: the game in exclusive fullscreen, say)
//   screens_fake.txt tests: monitors to use instead of the real ones, "x y w h" a line
#pragma once
#include "relay.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <string>
#include <vector>

namespace screens {

constexpr DWORD POLL_MS = 100;          // a load's "one" lands before its loading screen does
constexpr double CHECK_S = 0.5;         // a spread window is checked this often against where it should be
constexpr LONG TOUCH_PX = 2;            // monitors this close count as side by side
constexpr LONG MIN_SHARED_PX = 200;     // two monitors that share less of an edge than this aren't a pair
constexpr int MAX_FIXES = 5;            // put back this many times...
constexpr double FIX_SPAN_S = 10.0;     // ...within this long, and something keeps taking the window back: stop
constexpr double SETTLE_S = 0.4;        // our own move is given this long to land before a miss can count
constexpr UINT ANSWER_MS = 200;         // how long the game's window gets to answer "are you taking your messages?"
constexpr double ONE_LOOK_S = 1.0;      // with the window as the game had it, the plan it'd get is looked at this often

struct Box {
    LONG x = 0, y = 0, w = 0, h = 0;
    bool operator==(const Box& o) const { return x == o.x && y == o.y && w == o.w && h == o.h; }
};

struct Plan {
    bool ok = false;
    std::string split = "-";
    Box window;
    LONG mw = 0, mh = 0;
    bool operator==(const Plan& o) const { return ok == o.ok && split == o.split && window == o.window; }
};

struct Saved {                          // the window as the game had it, to put back
    bool have = false;                  // taken for the spread on now
    bool kept = false;                  // style and rect are the last ones taken, still after a put back
    LONG_PTR style = 0;
    RECT rect{};
};

struct Find {
    DWORD pid;
    HWND best;
    LONGLONG area;
};

BOOL CALLBACK each_window(HWND h, LPARAM l) {
    auto* f = reinterpret_cast<Find*>(l);
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != f->pid || !IsWindowVisible(h)) return TRUE;
    wchar_t cls[32] = {};
    if (!GetClassNameW(h, cls, 32) || wcscmp(cls, L"UnrealWindow") != 0) return TRUE;
    RECT r{};
    GetWindowRect(h, &r);
    const LONGLONG area = static_cast<LONGLONG>(r.right - r.left) * (r.bottom - r.top);
    if (area > f->area) {
        f->best = h;
        f->area = area;
    }
    return TRUE;
}

// The game's own window: the biggest of this process's Unreal windows that are showing.
HWND game_window() {
    Find f{GetCurrentProcessId(), nullptr, 0};
    EnumWindows(each_window, reinterpret_cast<LPARAM>(&f));
    return f.best;
}

BOOL CALLBACK each_monitor(HMONITOR m, HDC, LPRECT, LPARAM l) {
    MONITORINFO info{};
    info.cbSize = sizeof info;
    if (GetMonitorInfoW(m, &info)) {
        const RECT& r = info.rcMonitor;
        reinterpret_cast<std::vector<Box>*>(l)->push_back({r.left, r.top, r.right - r.left, r.bottom - r.top});
    }
    return TRUE;
}

std::vector<Box> monitors(const std::wstring& fake) {
    std::vector<Box> out;
    FILE* f = nullptr;
    if (_wfopen_s(&f, fake.c_str(), L"r") == 0 && f) {
        long x = 0, y = 0, w = 0, h = 0;
        while (fscanf_s(f, "%ld %ld %ld %ld", &x, &y, &w, &h) == 4)
            if (w > 0 && h > 0) out.push_back({x, y, w, h});
        fclose(f);
        return out;
    }
    EnumDisplayMonitors(nullptr, nullptr, each_monitor, reinterpret_cast<LPARAM>(&out));
    return out;
}

LONG shared(LONG a0, LONG a1, LONG b0, LONG b1) {
    return std::min(a1, b1) - std::max(a0, b0);
}

// The monitor the window is on: the one most of it covers.
Box home_of(const std::vector<Box>& mons, const RECT& r) {
    Box best;
    LONGLONG most = -1;
    for (const Box& m : mons) {
        const LONG w = shared(r.left, r.right, m.x, m.x + m.w), h = shared(r.top, r.bottom, m.y, m.y + m.h);
        const LONGLONG area = (w > 0 && h > 0) ? static_cast<LONGLONG>(w) * h : 0;
        if (area > most) {
            most = area;
            best = m;
        }
    }
    return best;
}

// The window for the home monitor and the one beside it: to its right, else its left, below, above. Side by side, the
// split is left/right and player 1 is on the left; one above the other, top/bottom and player 1 on top. Monitors of
// different sizes each get the smaller one's size, set against the edge they share, so the split falls on that edge.
Plan plan_for(const std::vector<Box>& mons, const Box& home) {
    for (int pass = 0; pass < 4; pass++) {
        for (const Box& o : mons) {
            if (o == home) continue;
            Box a = home, b = o;        // a: player 1's (left or top), b: player 2's
            bool touch = false;
            if (pass == 0) {
                touch = std::labs(o.x - (home.x + home.w)) <= TOUCH_PX;
            } else if (pass == 1) {
                touch = std::labs(home.x - (o.x + o.w)) <= TOUCH_PX;
                a = o;
                b = home;
            } else if (pass == 2) {
                touch = std::labs(o.y - (home.y + home.h)) <= TOUCH_PX;
            } else {
                touch = std::labs(home.y - (o.y + o.h)) <= TOUCH_PX;
                a = o;
                b = home;
            }
            if (!touch) continue;
            Plan p;
            if (pass < 2) {
                const LONG top = std::max(a.y, b.y), bottom = std::min(a.y + a.h, b.y + b.h);
                if (bottom - top < MIN_SHARED_PX) continue;
                const LONG edge = a.x + a.w, half = std::min(a.w, b.w);
                p = {true, "lr", {edge - half, top, 2 * half, bottom - top}, half, bottom - top};
            } else {
                const LONG left = std::max(a.x, b.x), right = std::min(a.x + a.w, b.x + b.w);
                if (right - left < MIN_SHARED_PX) continue;
                const LONG edge = a.y + a.h, half = std::min(a.h, b.h);
                p = {true, "tb", {left, edge - half, right - left, 2 * half}, right - left, half};
            }
            return p;
        }
    }
    return Plan{};
}

LONG_PTR spread_style(const Saved& saved) {
    return WS_POPUP | WS_VISIBLE | (saved.style & (WS_CLIPCHILDREN | WS_CLIPSIBLINGS));
}

// (Asynchronous: the game's thread moves its own window when it next reads its messages, so this thread never waits on
// a load. The style change does wait for that thread, which never waits on this one.)
void place(HWND h, const Box& b) {
    SetWindowPos(h, nullptr, b.x, b.y, b.w, b.h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_ASYNCWINDOWPOS);
}

Box box_of(const RECT& r) {
    return {r.left, r.top, r.right - r.left, r.bottom - r.top};
}

void spread(HWND h, const Plan& p, Saved& saved) {
    if (!saved.have) {
        RECT r{};
        GetWindowRect(h, &r);
        // (Put back a moment ago and that move not landed yet, the window still has the spread's size: the game's own is
        // the one kept from before. Taken from the window now, the next put back would leave it that size, with a border.)
        if (!(saved.kept && box_of(r) == p.window)) {
            saved.style = GetWindowLongPtrW(h, GWL_STYLE);
            saved.rect = r;
        }
        saved.have = saved.kept = true;
    }
    const LONG_PTR style = spread_style(saved);
    if (GetWindowLongPtrW(h, GWL_STYLE) != style) SetWindowLongPtrW(h, GWL_STYLE, style);
    place(h, p.window);
}

void put_back(HWND h, Saved& saved) {
    if (!saved.have) return;
    saved.have = false;
    if (!IsWindow(h)) return;
    SetWindowLongPtrW(h, GWL_STYLE, saved.style);
    const RECT& r = saved.rect;
    place(h, {r.left, r.top, r.right - r.left, r.bottom - r.top});
}

// Where the spread window is, and whether it still has the spread style.
bool still_spread(HWND h, const Plan& p, const Saved& saved) {
    RECT r{};
    if (!GetWindowRect(h, &r)) return false;
    return box_of(r) == p.window && GetWindowLongPtrW(h, GWL_STYLE) == spread_style(saved);
}

// Whether the game's thread is taking its window's messages: a hitch or a load holds our move with them, and the window
// not being where it was put means nothing then. (Asked of this thread only, which waits up to ANSWER_MS for it.)
bool taking_messages(HWND h) {
    DWORD_PTR result = 0;
    return SendMessageTimeoutW(h, WM_NULL, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, ANSWER_MS, &result) != 0;
}

// "" with no file (the option is off). A file caught empty as the mod writes it, or there and not opened, is "?": the
// last wish stands.
std::string read_want(const std::wstring& path) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"r") != 0 || !f)
        return GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES ? std::string() : std::string("?");
    char word[16] = {};
    const int got = fscanf_s(f, "%15s", word, static_cast<unsigned>(sizeof word));
    fclose(f);
    return got == 1 ? std::string(word) : std::string("?");
}

DWORD WINAPI watch(void* dir_) {
    const std::wstring dir = *static_cast<std::wstring*>(dir_);
    const std::wstring want_file = dir + L"\\screens.txt", out_file = dir + L"\\screens_out.txt",
                       fake_file = dir + L"\\screens_fake.txt";
    DeleteFileW(want_file.c_str());
    DeleteFileW(out_file.c_str());
    HWND window = nullptr;
    Saved saved;
    Plan plan, one_plan;                // the spread being held (the last one, once put back); the one shown while "one"
    bool spread_now = false, gave_up = false;
    std::string last_want, said;
    std::vector<double> fixes;
    double next_check = 0, spread_at = 0, one_look = -1e9;
    while (true) {
        Sleep(POLL_MS);
        std::string want = read_want(want_file);
        if (want == "?") want = last_want;
        if (want != last_want) gave_up = false;     // (a new wish is a new try)
        last_want = want;
        if (window && !IsWindow(window)) {
            window = nullptr;
            spread_now = false;
            saved = Saved{};
        }
        if (want != "two" && want != "one") {       // the file gone: the option is off, the window as the game had it
            if (spread_now) put_back(window, saved);
            spread_now = false;
            if (!said.empty()) {
                DeleteFileW(out_file.c_str());
                said.clear();
            }
            continue;
        }
        if (!window) window = game_window();
        std::string state, why = "ok";
        Plan shown;
        const double now = relay::monotonic();
        if (!window) {
            state = want == "two" ? "none" : "one";
            why = "nowindow";
        } else if (want == "one" || gave_up) {
            if (spread_now) put_back(window, saved);
            spread_now = false;
            if (now - one_look >= ONE_LOOK_S) {     // (only for the line the mod reads: no need every poll)
                one_look = now;
                RECT r{};
                GetWindowRect(window, &r);
                const std::vector<Box> mons = monitors(fake_file);
                one_plan = plan_for(mons, home_of(mons, r));
            }
            shown = one_plan;
            state = gave_up ? "none" : "one";
            if (gave_up) why = "fight";
        } else if (IsIconic(window)) {
            state = spread_now ? "two" : "one";     // (minimized: nothing to place until it's back)
            shown = plan;
        } else if (!spread_now) {
            RECT r{};
            GetWindowRect(window, &r);
            // (A put back not landed yet still has the spread's size, over both monitors: the game's own place says
            // which monitor is home.)
            const RECT from = (saved.kept && box_of(r) == plan.window) ? saved.rect : r;
            const std::vector<Box> mons = monitors(fake_file);
            const Plan p = plan_for(mons, home_of(mons, from));
            if (p.ok) {
                spread(window, p, saved);
                plan = p;
                spread_now = true;
                fixes.clear();
                spread_at = now;
                next_check = now + CHECK_S * 2;     // (the move is asynchronous: the first look waits for it)
                state = "two";
            } else {
                state = "none";
                why = "single";
            }
            shown = p;
        } else {
            state = "two";
            if (now >= next_check) {
                next_check = now + CHECK_S;
                // The monitors as they are now, from where the game had its window: a monitor unplugged, moved or
                // resized gives a new spread, or none.
                const std::vector<Box> mons = monitors(fake_file);
                const Plan p = plan_for(mons, home_of(mons, saved.rect));
                if (!p.ok) {
                    put_back(window, saved);
                    spread_now = false;
                    state = "none";
                    why = "single";
                } else if (!(p == plan)) {
                    plan = p;
                    spread(window, p, saved);
                    spread_at = now;
                } else if (still_spread(window, plan, saved) || now - spread_at < SETTLE_S) {
                    // in place, or our own move not due yet
                } else if (taking_messages(window)) {
                    // The game takes its messages and the window isn't where it was put: the game (or the player) moved
                    // it. Put again, and counted. (Not while it's held up: our move just waits with its messages then.)
                    fixes.erase(std::remove_if(fixes.begin(), fixes.end(), [&](double t) { return now - t > FIX_SPAN_S; }),
                                fixes.end());
                    fixes.push_back(now);
                    if (static_cast<int>(fixes.size()) > MAX_FIXES) {
                        put_back(window, saved);
                        spread_now = false;
                        gave_up = true;
                        state = "none";
                        why = "fight";
                    } else {
                        spread(window, plan, saved);
                        spread_at = now;
                    }
                }
            }
            shown = plan;
        }
        char line[160];
        sprintf_s(line, "%s %s %ld %ld %ld %ld %s\n", state.c_str(), shown.ok ? shown.split.c_str() : "-",
                  static_cast<long>(shown.window.w), static_cast<long>(shown.window.h), static_cast<long>(shown.mw),
                  static_cast<long>(shown.mh), why.c_str());
        if (said != line) {
            relay::write_atomic(out_file, line);
            said = line;
        }
    }
}

}  // namespace screens
