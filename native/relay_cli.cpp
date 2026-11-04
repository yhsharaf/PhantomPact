// The relay with no game around it, for tests only (never shipped):
//   relay_cli test                      the logic against simulated connections
//   relay_cli bot host|client [options] a stand-in for the game on one end of a real relay: it plays a known path at
//                                       60 frames a second and measures what arrives. Two bots on one PC share a clock,
//                                       so every delay it prints is the true one.
//   relay_cli netem <listen port> <target port> [options]   a bad connection between two ports on this PC
//   relay_cli latency [options]         the partner's figure end to end in simulated time, over a grid of connections
//                                       and frame rates: how far behind it shows, and how smoothly (latency.hpp)
#include "relay.hpp"
#include "latency.hpp"

#include <limits>
#include <queue>
#include <random>
#include <thread>

namespace {

using relay::monotonic;

// A bad connection between two ports on this PC.
struct Netem {
    int listen = 0, target = 0;
    double delay = 10, jitter = 0, loss = 0, duplicate = 0, seconds = 60, stall_every = 0, stall_ms = 200;
};

int netem(const Netem& o, const std::atomic<bool>* stop);

constexpr double PI = 3.14159265358979323846;

// The bots' path: a circle whose position alone says when it was sampled.
constexpr double RADIUS_CM = 1000, SPEED_CM_S = 600;
const double TURN_RATE = SPEED_CM_S / RADIUS_CM;      // radians per second

double opt_number(int argc, wchar_t** argv, const wchar_t* name, double fallback) {
    for (int i = 1; i + 1 < argc; i++)
        if (std::wcscmp(argv[i], name) == 0) return _wtof(argv[i + 1]);
    return fallback;
}

std::wstring opt_text(int argc, wchar_t** argv, const wchar_t* name, const wchar_t* fallback) {
    for (int i = 1; i + 1 < argc; i++)
        if (std::wcscmp(argv[i], name) == 0) return argv[i + 1];
    return fallback;
}

struct Stats {
    std::vector<double> v;
    void add(double x) { v.push_back(x); }
    double pick(double p) {
        if (v.empty()) return 0;
        std::sort(v.begin(), v.end());
        return v[std::min(v.size() - 1, static_cast<size_t>(v.size() * p))];
    }
    void print(const char* name) {
        std::printf("%-26s n=%-6zu p50 %7.1f  p95 %7.1f  p99 %7.1f  max %7.1f\n", name, v.size(), pick(0.5), pick(0.95), pick(0.99), pick(1.0));
    }
};

int checks_failed = 0;

void check(bool ok, const std::string& what) {
    std::printf("  %s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    if (!ok) checks_failed++;
}

// A simulated run of the Timeline: the sender samples at 60 Hz along a line, the network delays each sample.
struct TimelineRun {
    double error_p95 = 0, error_max = 0, step_error_max = 0, delay_end = 0;
};

TimelineRun simulate_timeline(double base_ms, double jitter_ms, double loss, double stall_every_ms, double stall_ms) {
    std::mt19937 rng(1234);
    std::uniform_real_distribution<double> unit(0, 1);
    struct Arrival {
        double at;
        relay::Sample s;
        bool operator<(const Arrival& o) const { return at > o.at; }
    };
    std::priority_queue<Arrival> wire;
    relay::Timeline line;
    const double speed = 600;       // cm/s
    double next_sample = 0, next_stall = stall_every_ms, stall_end = 0;
    Stats errors;
    double last_x = 0, last_t = -1, worst_step = 0;
    for (double t = 0; t < 30000; t += 16.667) {
        while (next_sample <= t) {
            relay::Sample s;
            s.ms = static_cast<uint32_t>(next_sample + 5000);
            s.x = static_cast<float>(speed * next_sample / 1000.0);
            s.vx = static_cast<float>(speed);
            s.flags = relay::FLAG_GROUNDED;
            if (stall_every_ms > 0 && next_sample >= next_stall) {
                stall_end = next_sample + stall_ms;
                next_stall += stall_every_ms;
            }
            double arrive = next_sample + base_ms + unit(rng) * jitter_ms;
            if (next_sample < stall_end) arrive = std::max(arrive, stall_end + base_ms);
            if (unit(rng) >= loss) wire.push({arrive, s});
            next_sample += 16.667;
        }
        while (!wire.empty() && wire.top().at <= t) {
            line.push(wire.top().s, t + 100000);
            wire.pop();
        }
        relay::Sample out;
        if (!line.at(t + 100000, out)) continue;
        if (t > 3000) {
            // How far the shown position is from where the partner really was base + delay ago.
            const double truth = speed * (t - base_ms - line.delay_ms()) / 1000.0;
            errors.add(std::fabs(out.x - truth));
            if (last_t >= 0) {
                const double step = out.x - last_x, ideal = speed * (t - last_t) / 1000.0;
                worst_step = std::max(worst_step, std::fabs(step - ideal));
            }
        }
        last_x = out.x;
        last_t = t;
    }
    TimelineRun r;
    r.error_p95 = errors.pick(0.95);
    r.error_max = errors.pick(1.0);
    r.step_error_max = worst_step;
    r.delay_end = line.delay_ms();
    return r;
}

void test_timeline() {
    std::puts("timeline:");
    TimelineRun clean = simulate_timeline(15, 0, 0, 0, 0);
    std::printf("  clean link: delay %.1f ms, error p95 %.1f cm, worst step error %.1f cm\n", clean.delay_end, clean.error_p95, clean.step_error_max);
    check(clean.delay_end < 25, "a clean link adds under 25 ms");
    check(clean.step_error_max < 3, "a clean link moves evenly");

    TimelineRun wifi = simulate_timeline(15, 8, 0.02, 0, 0);
    std::printf("  jitter 8 ms, loss 2%%: delay %.1f ms, error p95 %.1f cm, worst step error %.1f cm\n", wifi.delay_end, wifi.error_p95, wifi.step_error_max);
    check(wifi.delay_end < 45, "a jittery link adds under 45 ms");
    check(wifi.step_error_max < 12, "jitter and 2% loss stay smooth");

    TimelineRun lossy = simulate_timeline(40, 15, 0.1, 0, 0);
    std::printf("  jitter 15 ms, loss 10%%: delay %.1f ms, worst step error %.1f cm\n", lossy.delay_end, lossy.step_error_max);
    check(lossy.step_error_max < 30, "10% loss has no visible jumps");

    TimelineRun stall = simulate_timeline(15, 3, 0, 5000, 300);
    std::printf("  300 ms stall every 5 s: delay %.1f ms, worst step error %.1f cm, worst error %.1f cm\n", stall.delay_end, stall.step_error_max, stall.error_max);
    check(stall.step_error_max < 200, "a 300 ms stall doesn't teleport the ghost");

    relay::Timeline line;
    relay::Sample a, b;
    a.ms = 1000;
    a.x = 0;
    b.ms = 1016;
    b.x = 50000;
    line.push(a, 2000);
    line.push(b, 2016);
    relay::Sample out;
    line.at(2020, out);
    line.at(2500, out);
    check(out.x == 50000, "a teleport lands in one step, with no slide across the map");

    // The sender's clock starting over is a new session, and must not leave the path stuck in the past.
    relay::Timeline again;
    relay::Sample c;
    for (uint32_t i = 0; i < 60; i++) {
        c.ms = 100000 + i * 16;
        c.x = static_cast<float>(i);
        again.push(c, 500000 + i * 16.0);
    }
    again.at(500000 + 60 * 16.0, out);
    again.clear();
    for (uint32_t i = 0; i < 60; i++) {
        c.ms = 50 + i * 16;
        c.x = 7000.0f + i;
        again.push(c, 501000 + i * 16.0);
    }
    check(again.at(501000 + 60 * 16.0, out) && out.x > 7000, "a restarted sender is followed at once");
}

void test_lanes() {
    std::puts("lanes:");
    std::mt19937 rng(99);
    std::uniform_real_distribution<double> unit(0, 1);
    relay::SureSender out;
    relay::SureReceiver in;
    std::vector<std::string> got;
    const int total = 2000;
    int pushed = 0;
    struct Item {
        double at;
        uint32_t id;
        std::string text;
        bool operator<(const Item& o) const { return at > o.at; }
    };
    std::priority_queue<Item> wire;
    double worst_wait = 0;
    std::map<std::string, double> born;
    for (double now = 0; now < 60 && (int)got.size() < total; now += 0.0167) {
        for (int i = 0; i < 2 && pushed < total; i++) {
            std::string text = "ev" + std::to_string(pushed++);
            born[text] = now;
            out.push(text);
        }
        out.for_each_due(now, 0.09, [&](const relay::SureSender::Item& item) {
            if (unit(rng) >= 0.3) wire.push({now + 0.03 + unit(rng) * 0.03, item.id, item.text});
            return true;
        });
        while (!wire.empty() && wire.top().at <= now) {
            in.on_event(wire.top().id, wire.top().text, [&](const std::string& t) {
                got.push_back(t);
                worst_wait = std::max(worst_wait, now - born[t]);
                return true;
            });
            wire.pop();
        }
        if (unit(rng) >= 0.3) out.on_ack(in.next(), in.bits());
    }
    bool ordered = true;
    for (int i = 0; i < (int)got.size(); i++)
        if (got[i] != "ev" + std::to_string(i)) ordered = false;
    check((int)got.size() == total, "every sure event arrives at 30% loss (" + std::to_string(got.size()) + ")");
    check(ordered, "in order and exactly once");
    std::printf("  worst wait %.0f ms at 30%% loss, %lld resends\n", worst_wait * 1000, out.resent);
    check(worst_wait < 1.2, "no event waits over 1.2 s at 30% loss");

    relay::SureSender r;
    r.push("a");
    r.push("b");
    r.forget();
    r.push("c");
    uint32_t first = 0;
    std::string first_text;
    r.for_each_due(1.0, 0.1, [&](const relay::SureSender::Item& item) {
        if (!first) {
            first = item.id;
            first_text = item.text;
        }
        return true;
    });
    check(first == 1 && first_text == "c", "a new partner gets nothing meant for the last one, and numbers from 1");

    // A held event whose turn comes while the game has no room: acknowledged already (bits), it's never sent again, so it
    // must be tried again from here, by the next event that comes or by the relay's own flush.
    relay::SureReceiver held;
    std::vector<std::string> took;
    int room = 99;                          // how many more the game takes
    auto give = [&](const std::string& t) {
        if (room <= 0) return false;
        room--;
        took.push_back(t);
        return true;
    };
    held.on_event(2, "two", give);          // ahead: held, and acknowledged in bits
    room = 1;
    held.on_event(1, "one", give);          // "one" in; "two" next, with no room: stuck, never sent again
    check(took.size() == 1 && held.next() == 2, "a held event the game has no room for waits");
    room = 99;
    held.drain(give);                       // the relay's flush
    check(took.size() == 2 && took[1] == "two" && held.next() == 3, "and goes in from the flush, once there's room");
    held.on_event(5, "five", give);         // held
    room = 1;
    held.on_event(3, "three", give);        // in
    held.on_event(4, "four", give);         // no room: "four" waits to be sent again
    room = 99;
    held.on_event(6, "six", give);          // held; nothing in: "four" isn't here
    held.on_event(4, "four", give);         // sent again: in, then "five" and "six"
    check(took.size() == 6 && took[3] == "four" && took[5] == "six", "in order to the end");

    relay::QuickReceiver q;
    check(q.fresh(5), "quick: first sight plays");
    check(!q.fresh(5), "quick: a repeat doesn't play twice");
    check(q.fresh(7), "quick: newer plays");
    check(q.fresh(6), "quick: late but unseen plays");
    check(!q.fresh(6), "quick: and only once");
    check(q.fresh(1000) && !q.fresh(5), "quick: far older is dropped");
    check(!q.fresh(1000u + 0x80000000u), "quick: an id exactly half the number space away is refused");

    relay::QuickSender alone;
    alone.push("old", 0);
    alone.expire(70);
    check(alone.empty(), "quick: a move made with nobody connected doesn't wait for one");
    alone.push("old", 0);
    bool went = false;
    alone.for_each(65.6, 0.012, [&](const relay::QuickSender::Item&, double) { return went = true; });
    check(!went, "quick: too old to send isn't sent, even once");

    relay::SureSender ack;
    ack.push("a");
    ack.on_ack(500, 0);
    check(ack.pending() == 1, "sure: an acknowledgement of something never sent confirms nothing");
}

void test_packets() {
    std::puts("packets:");
    relay::Sample s;
    s.ms = 123456;
    s.x = 275793.5f;
    s.y = -32341.25f;
    s.z = 12.5f;
    s.yaw = -179.5f;
    s.vx = 600;
    s.vy = -600;
    s.vz = 40000;           // clamped
    s.hp = 850;
    s.max_hp = 1200;
    s.map = 0xDEADBEEF;
    s.flags = 3;
    std::string bytes;
    relay::Writer w(bytes);
    relay::put_sample(w, s);
    relay::Reader r(bytes);
    relay::Sample back = relay::get_sample(r);
    check(r.ok && !r.left(), "a sample reads back whole (" + std::to_string(bytes.size()) + " bytes)");
    check(back.x == s.x && back.yaw == s.yaw && back.hp == s.hp && back.map == s.map && back.flags == s.flags, "fields survive");
    check(back.vz == 32000, "speeds are clamped, not wrapped");
    std::string cut = bytes.substr(0, 10);
    relay::Reader short_read(cut);
    relay::get_sample(short_read);
    check(!short_read.ok, "a cut-off packet is refused");
    s.vx = std::numeric_limits<float>::quiet_NaN();
    std::string odd;
    relay::Writer odd_writer(odd);
    relay::put_sample(odd_writer, s);
    relay::Reader odd_reader(odd);
    check(relay::get_sample(odd_reader).vx == 0, "a speed that isn't a number goes out as 0");
}

// Sends a stretch of a sender on a straight line at 600 cm/s through a 20 ms link, its clock moved by jump_ms from
// jump_at_ms on. What matters is the ghost's distance to where the partner really was once things have settled.
struct JumpRun {
    double worst_after = 0, longest_stale_ms = 0;
    bool finite = true;
};

JumpRun clock_jump(double jump_ms) {
    relay::Timeline line;
    constexpr double SPEED = 600, TRIP = 20, JUMP_AT = 8000, END = 34000;
    JumpRun r;
    double stale_from = -1;
    for (double t = 0; t < END; t += 16.667) {
        relay::Sample s;
        s.ms = static_cast<uint32_t>(1000000 + t + (t >= JUMP_AT ? jump_ms : 0));
        s.x = static_cast<float>(SPEED * t / 1000);
        s.vx = static_cast<float>(SPEED);
        s.flags = relay::FLAG_GROUNDED;
        line.push(s, 5000 + t + TRIP);
        relay::Sample out;
        if (!line.at(5000 + t + TRIP, out)) continue;
        r.finite = r.finite && std::isfinite(out.x);
        if (t >= JUMP_AT) {
            if (out.flags & relay::FLAG_STALE) {
                if (stale_from < 0) stale_from = t;
                r.longest_stale_ms = std::max(r.longest_stale_ms, t - stale_from);
            } else {
                stale_from = -1;
            }
        }
        if (t > JUMP_AT + 20000) r.worst_after = std::max(r.worst_after, std::fabs(out.x - SPEED * t / 1000));
    }
    return r;
}

void test_timeline_odd() {
    std::puts("timeline, odd clocks:");
    relay::Sample out;
    relay::Timeline same;
    bool finite = true;
    for (int i = 0; i < 300; i++) {
        relay::Sample s;
        s.ms = 5000;
        s.x = static_cast<float>(i);
        same.push(s, 9000 + i * 16.0);
        same.at(9000 + i * 16.0, out);
        finite = finite && std::isfinite(out.x) && std::isfinite(out.y);
    }
    check(finite, "samples all stamped the same moment stay finite");

    relay::Timeline burst;
    for (int i = 0; i < 200; i++) {
        relay::Sample s;
        s.ms = 5000 + i * 16;
        s.x = i * 10.0f;
        burst.push(s, 9000);
    }
    burst.at(9000, out);
    finite = std::isfinite(out.x);
    burst.at(9500, out);
    check(finite && std::isfinite(out.x), "samples that all land in the same instant stay finite");

    for (double jump : {500.0, 5000.0, 600000.0, -200.0, -500.0, -1000.0, -5000.0, -600000.0}) {
        const JumpRun r = clock_jump(jump);
        char what[120];
        std::snprintf(what, sizeof what, "the sender's clock jumps %+.0f ms: settled to %.0f cm, stale for at most %.0f ms", jump, r.worst_after, r.longest_stale_ms);
        check(r.finite && r.worst_after < 60 && r.longest_stale_ms < 1000, what);
    }

    // A long silence, and the link comes back slower: the fast trips from before it mustn't count for 6 s more.
    relay::Timeline back;
    double ms = 100000, worst = 0;
    relay::Sample s;
    for (int i = 0; i < 400; i++, ms += 16) {
        s.ms = static_cast<uint32_t>(ms);
        s.x = 0;
        back.push(s, ms + 10);
        back.at(ms + 10, out);
    }
    ms += 60000;
    bool stale = false;
    for (int i = 0; i < 180; i++, ms += 16) {
        s.ms = static_cast<uint32_t>(ms);
        s.x = static_cast<float>(ms * 0.6);
        s.vx = 600;
        back.push(s, ms + 110);
        back.at(ms + 110, out);
        if (i >= 60) {
            stale = stale || (out.flags & relay::FLAG_STALE);
            worst = std::max(worst, std::fabs(out.x - ms * 0.6));
        }
    }
    check(!stale && worst < 150, "back from a minute's silence on a slower link, it follows at once (" + std::to_string(static_cast<int>(worst)) + " cm)");

    // A teleport with a sample that arrives late, on the far side of it: still no slide across the map.
    relay::Timeline hop;
    relay::Sample a, b, c;
    a.ms = 10000;
    b.ms = 10016;
    b.x = 50000;
    c.ms = 10032;
    c.x = 50001;
    hop.push(a, 20000);
    hop.at(20000, out);
    hop.push(c, 20032);
    hop.push(b, 20033);
    bool slid = false;
    for (double now = 20000; now < 20300; now += 2) {
        hop.at(now, out);
        slid = slid || (out.x > 1 && out.x < 49000);
    }
    check(!slid, "a late sample behind a teleport doesn't make it slide");
}

// The ghost walks at the speed it's told, so that speed must be the sender's own: the mod's tick comes at another moment of
// each frame, and the step between two stamps swings with it. Unless the sender is carried: then the path's.
void test_timeline_speed() {
    std::puts("timeline, speed:");
    std::mt19937 rng(77);
    std::uniform_real_distribution<double> unit(0, 1);
    relay::Timeline line;
    relay::Sample s, out;
    s.flags = relay::FLAG_GROUNDED;
    double worst = 0, next_frame = 0;
    for (int i = 0; i < 600; i++) {
        const double moved = i * 16.667;               // the game moves the player at the frame...
        s.ms = static_cast<uint32_t>(10000 + moved + unit(rng) * 4);     // ...and the tick stamps it a little later
        s.x = static_cast<float>(moved * 0.6);
        s.vx = 600;
        line.push(s, 50000 + s.ms + 30);
        for (; next_frame <= s.ms + 30; next_frame += 16.667) {
            if (!line.at(50000 + next_frame, out) || i < 120) continue;
            worst = std::max(worst, std::fabs(out.vx - 600.0));
        }
    }
    char what[120];
    std::snprintf(what, sizeof what, "the speed it plays is the sender's, whenever the tick came (%.0f cm/s off at worst)", worst);
    check(worst < 30, what);

    relay::Timeline lift;
    for (int i = 0; i < 300; i++) {
        s.ms = static_cast<uint32_t>(10000 + i * 16);
        s.x = static_cast<float>(i * 16 * 0.3);     // 300 cm/s, and the sender's own speed says it stands
        s.vx = 0;
        lift.push(s, 50000 + i * 16.0 + 20);
        lift.at(50000 + i * 16.0 + 20, out);
    }
    std::snprintf(what, sizeof what, "carried by something, it's told the path's speed (%.0f cm/s of 300)", out.vx);
    check(std::fabs(out.vx - 300) < 30, what);
    const float last_x = out.x;
    lift.at(50000 + 300 * 16.0 + 60, out);          // a sample late: the guess goes on at that speed too
    std::snprintf(what, sizeof what, "and a guess past the last sample goes on at it (%.1f cm on in 56 ms)", out.x - last_x);
    check(out.x - last_x > 12 && out.x - last_x < 22, what);
}

// The partner end to end (latency.hpp), sending as coop.lua does. When these numbers were chosen, an 80 ms link with
// 10 ms of jitter and 2% loss played the partner 85 ms behind with a ghost speed off by 75 cm/s (95th percentile).
void test_latency() {
    std::puts("latency, end to end:");
    const lab::Path stops = lab::make_path("stops", 40, 11);
    const lab::Sending sending{0, 0, 125};
    lab::TimelinePlayback bad, clean;
    lab::Run r = lab::run(stops, nullptr, {80, 10, 2}, 60, 60, bad, 5, sending);
    char what[140];
    std::snprintf(what, sizeof what, "80 ms link, 10 ms jitter, 2%% loss: %.0f ms behind, %.0f ms at the 95th percentile",
                  r.target.behind(0.5), r.target.behind(0.95));
    check(r.target.behind(0.5) < 70 && r.target.behind(0.95) < 75, what);
    std::snprintf(what, sizeof what, "a sudden stop runs on %.1f cm at most", r.target.overshoot(1.0));
    check(r.target.overshoot(1.0) < 6, what);
    std::snprintf(what, sizeof what, "the ghost's speed stays steady: %.0f cm/s off at the 95th percentile", r.ghost.speed(0.95));
    check(r.ghost.speed(0.95) < 40, what);
    lab::Run c = lab::run(stops, nullptr, {30, 0, 0}, 60, 60, clean, 6, sending);
    std::snprintf(what, sizeof what, "30 ms clean link: %.0f ms behind", c.target.behind(0.5));
    check(c.target.behind(0.5) < 38, what);
}

// Two real Relay objects through a network in memory, in simulated time: every packet is at the test's mercy.

relay::Addr at(uint32_t ip) {
    relay::Addr a;
    a.ip = ip;
    a.port = 1000;
    return a;
}

void split_lines(const std::string& text, std::vector<std::string>& into) {
    for (size_t pos = 0; pos < text.size();) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        into.push_back(text.substr(pos, end - pos));
        pos = end + 1;
    }
}

struct FakeNet {
    struct Packet {
        double at;
        long long order;
        relay::Addr from;
        std::string data;
        bool operator<(const Packet& o) const { return at != o.at ? at > o.at : order > o.order; }
    };

    double now = 1000, delay = 0.005, jitter = 0, loss = 0, dup = 0;
    bool down = false;
    uint32_t hold_from = 0;       // packets from this address stay on the way until let_go()
    std::vector<std::pair<uint32_t, Packet>> held;
    std::map<uint32_t, std::priority_queue<Packet>> wires;
    std::mt19937 rng{2026};
    size_t biggest = 0;
    long long carried = 0, order = 0;

    double unit() { return std::uniform_real_distribution<double>(0, 1)(rng); }

    void send(const relay::Addr& from, const relay::Addr& to, const std::string& data) {
        biggest = std::max(biggest, data.size());
        carried++;
        if (down || unit() < loss) return;
        Packet p{now + delay + unit() * jitter, order++, from, data};
        if (from.ip == hold_from) {
            held.emplace_back(to.ip, std::move(p));
            return;
        }
        wires[to.ip].push(p);
        if (unit() < dup) {
            p.at += unit() * 0.02;
            p.order = order++;
            wires[to.ip].push(p);
        }
    }

    void let_go() {
        for (auto& [to, p] : held) {
            p.at = now;
            wires[to].push(p);
        }
        held.clear();
        hold_from = 0;
    }

    std::vector<std::pair<relay::Addr, std::string>> take(uint32_t ip) {
        std::vector<std::pair<relay::Addr, std::string>> out;
        auto& wire = wires[ip];
        while (!wire.empty() && wire.top().at <= now) {
            out.emplace_back(wire.top().from, wire.top().data);
            wire.pop();
        }
        return out;
    }
};

class FakeLink : public relay::Link {
public:
    FakeLink(FakeNet& net, const relay::Addr& me, std::optional<relay::Addr> host, std::vector<relay::Addr> friends)
        : net_(net), me_(me), friends_(std::move(friends)) {
        peer = host;
    }
    void send(const relay::Addr& to, const std::string& data) override { net_.send(me_, to, data); }
    std::vector<std::pair<relay::Addr, std::string>> receive() override {
        std::vector<std::pair<relay::Addr, std::string>> out;
        for (auto& [from, data] : net_.take(me_.ip)) {
            if (peer && from != *peer) filtered++;     // what UdpLink does
            else out.emplace_back(from, std::move(data));
        }
        return out;
    }
    void wait(double, HANDLE) override {}
    std::vector<relay::Addr> candidates() override { return friends_; }
    std::string describe(const relay::Addr& a) override { return "pc" + std::to_string(a.ip); }
    std::string describe_self() override { return "pc" + std::to_string(me_.ip); }
    const char* via() override { return "fake"; }

private:
    FakeNet& net_;
    relay::Addr me_;
    std::vector<relay::Addr> friends_;
};

// One player: their relay, and what their game has read from it.
struct End {
    End(FakeNet& net, const char* role, uint32_t ip, std::optional<relay::Addr> host = std::nullopt, const relay::Ini& ini = {},
        const std::string* secret = nullptr, std::vector<relay::Addr> friends = {})
        : addr(at(ip)), net_(net) {
        relay = std::make_unique<relay::Relay>(role, L".", std::make_unique<FakeLink>(net, addr, host, std::move(friends)), secret, ini,
                                               "1.5.0", [](const std::string&) {}, box);
    }

    void step() {
        relay->tick(net_.now);
        if (reading) split_lines(box.take_events(relay::clock_ms()), events);
    }

    std::string status() { return relay->status(net_.now); }

    std::string field(const std::string& key) {
        const std::string line = " " + status() + " ", tag = " " + key + "=";
        const size_t from = line.find(tag);
        if (from == std::string::npos) return "";
        const size_t start = from + tag.size();
        return line.substr(start, line.find(' ', start) - start);
    }

    int count(const std::string& line) const { return static_cast<int>(std::count(events.begin(), events.end(), line)); }

    relay::Mailbox box;
    relay::Addr addr;
    std::unique_ptr<relay::Relay> relay;
    std::vector<std::string> events;
    bool reading = true;              // false: the game thread is stuck in a load

private:
    FakeNet& net_;
};

void run(FakeNet& net, std::initializer_list<End*> ends, double seconds) {
    for (double t = 0; t < seconds; t += 0.005) {
        net.now += 0.005;
        for (End* e : ends) e->step();
    }
}

// True if exactly name0..name<total - 1> arrived among the events, in that order.
bool in_order(const std::vector<std::string>& events, const std::string& name, int total) {
    int next = 0;
    for (const std::string& e : events) {
        if (e.rfind(name, 0) != 0) continue;
        if (e.compare(0, e.find(' '), name + std::to_string(next)) != 0) return false;
        next++;
    }
    return next == total;
}

std::string padded(const std::string& name, int i, size_t bytes) {
    std::string text = name + std::to_string(i) + " ";
    text.resize(std::max(text.size(), bytes), 'x');
    return text;
}

struct RawHeader {
    uint8_t flags = 0;
    uint32_t session = 7, view = 0;
    uint16_t sequence = 0;
    uint32_t ms = 1000, echo = 0;
    uint16_t hold = 0;
    uint32_t ack = 1, bits = 0;
};

// A packet that didn't come from a Relay: this test is the partner, and picks every field.
std::string raw_packet(const RawHeader& h, const std::string& rest = "") {
    std::string p;
    relay::Writer w(p);
    w.put<uint8_t>(relay::MARKER);
    w.put<uint8_t>(relay::PROTOCOL);
    w.put<uint8_t>(h.flags);
    w.put<uint32_t>(h.session);
    w.put<uint32_t>(h.view);
    w.put<uint16_t>(h.sequence);
    w.put<uint32_t>(h.ms);
    w.put<uint32_t>(h.echo);
    w.put<uint16_t>(h.hold);
    w.put<uint32_t>(h.ack);
    w.put<uint32_t>(h.bits);
    return p + rest;
}

constexpr uint32_t ip4(uint32_t a, uint32_t b, uint32_t c, uint32_t d) { return (a << 24) | (b << 16) | (c << 8) | d; }

void test_partners() {
    std::puts("who talks to whom:");
    for (uint32_t ip : {ip4(100, 101, 102, 103), ip4(192, 168, 1, 20), ip4(10, 0, 0, 5), ip4(172, 20, 1, 1), ip4(127, 0, 0, 1), ip4(25, 1, 2, 3), ip4(26, 9, 9, 9), ip4(169, 254, 1, 1)})
        check(relay::address_allowed(ip), "a partner's range is let in: " + std::to_string(ip >> 24) + ".x");
    for (uint32_t ip : {ip4(8, 8, 8, 8), ip4(203, 0, 113, 7), ip4(100, 63, 0, 1), ip4(172, 32, 0, 1), ip4(1, 1, 1, 1)})
        check(!relay::address_allowed(ip), "the open internet isn't: " + std::to_string(ip >> 24) + "." + std::to_string((ip >> 16) & 255) + ".x");

    FakeNet net;
    End host(net, "host", 1), first(net, "client", 2, at(1));
    run(net, {&host, &first}, 0.3);
    check(host.field("connected") == "yes" && first.field("connected") == "yes", "a guest and a host find each other");
    check(host.count("S") == 1 && first.count("S") == 1, "and each tells its game once");

    End second(net, "client", 3, at(1));
    run(net, {&host, &first, &second}, 1.0);
    check(host.field("peer") == "pc2", "the host stays with its first guest");
    check(second.field("connected") == "no", "a second sender gets no answer while the first is alive");
    host.box.post_sure("for first");
    run(net, {&host, &first, &second}, 0.3);
    check(first.count("for first") == 1 && second.count("for first") == 0, "and hears nothing meant for the first");

    run(net, {&host, &second}, relay::PEER_TIMEOUT + 0.5);
    check(host.field("peer") == "pc3", "once the first has gone silent the second is taken");
    host.box.post_sure("for second");
    second.box.post_sure("from second");
    run(net, {&host, &second}, 0.3);
    check(second.count("for second") == 1 && host.count("from second") == 1, "and the lanes work with it");
    check(host.count("S") == 2, "the game hears of the new partner");

    // A Steam guest looks through its friends in the game: only a host answers, and another guest is never taken for one.
    FakeNet steam;
    End friend_host(steam, "host", 11), friend_guest(steam, "client", 13), seeker(steam, "client", 12, std::nullopt, {}, nullptr, {at(13), at(11)});
    run(steam, {&friend_host, &friend_guest, &seeker}, 1.5);
    check(seeker.field("peer") == "pc11" && friend_host.field("peer") == "pc12", "a guest pins the friend who is hosting");
    check(friend_guest.field("peer") == "-", "a guest never answers a guest");

    // On a guest the link itself refuses everyone but the host, whatever they say.
    End guest(net, "client", 4, at(1));
    RawHeader fake;
    fake.flags = relay::FLAG_FROM_HOST;
    net.send(at(9), guest.addr, raw_packet(fake));
    run(net, {&guest}, 0.1);
    check(guest.field("filtered") == "1" && guest.field("connected") == "no", "a guest takes nothing from a stranger's address");
}

void test_secret() {
    std::puts("secret:");
    const std::string secret = "correct horse battery", other = "something else";
    relay::Auth sealer(secret, "host"), opener(secret, "client");
    const std::string p = sealer.seal("hello");
    const auto opened = opener.open(p);
    check(opened && *opened == "hello", "a signed packet opens");
    check(!opener.open(p), "a replayed packet is refused");
    const std::string first = sealer.seal("a"), second = sealer.seal("b");
    check(opener.open(second) && opener.open(first), "a signed packet that arrives late isn't a replay");
    check(!opener.open(first) && !opener.open(second), "but counts once");
    std::string tampered = sealer.seal("hello");
    tampered[30] ^= 1;
    check(!opener.open(tampered), "a tampered packet is refused");
    check(!sealer.open(sealer.seal("x")), "a packet bounced back at its sender is refused");
    relay::Auth second_host(secret, "host");
    check(!sealer.open(second_host.seal("x")), "a packet from the same role is refused");
    relay::Auth wrong(other, "client");
    check(!wrong.open(sealer.seal("x")), "the wrong secret opens nothing");
    check(!opener.open("{\"t\":\"state\"}"), "an unsigned packet is refused when a secret is set");
    const std::string key = crypto::hmac_sha256(crypto::scrypt(secret, "PhantomPact/relay/1", 1 << 14, 8, 32), "packet-mac");
    std::string body(relay::Auth::MAGIC, 4);
    body.push_back('H');
    body += "12345678";
    relay::Auth::put_u64(body, 1);
    relay::Auth::put_u64(body, static_cast<uint64_t>((relay::wall_seconds() - relay::Auth::REPLAY_WINDOW_S - 5) * 1000));
    body += "x";
    check(!opener.open(body + crypto::hmac_sha256(key, body)), "a signed packet from minutes ago is refused");
    const std::string whole = sealer.seal("cut me");
    bool any = false;
    for (size_t n = 0; n < whole.size(); n++) any = any || opener.open(whole.substr(0, n)).has_value();
    check(!any, "a signed packet cut at any byte is refused");

    FakeNet same;
    End host(same, "host", 1, std::nullopt, {}, &secret), guest(same, "client", 2, at(1), {}, &secret);
    run(same, {&host, &guest}, 0.3);
    host.box.post_sure("signed");
    run(same, {&host, &guest}, 0.3);
    check(guest.field("connected") == "yes" && guest.count("signed") == 1 && guest.field("auth") == "on", "the same secret connects");

    FakeNet differ;
    End host2(differ, "host", 1, std::nullopt, {}, &secret), guest2(differ, "client", 2, at(1), {}, &other);
    run(differ, {&host2, &guest2}, 1.0);
    check(host2.field("peer") == "-" && host2.field("rejected") != "0", "different secrets never connect, and the host counts them");

    FakeNet one;
    End host3(one, "host", 1, std::nullopt, {}, &secret), guest3(one, "client", 2, at(1));
    run(one, {&host3, &guest3}, 1.0);
    check(host3.field("peer") == "-" && host3.field("rejected") != "0", "a secret on the host alone doesn't connect");

    FakeNet two;
    End host4(two, "host", 1), guest4(two, "client", 2, at(1), {}, &secret);
    run(two, {&host4, &guest4}, 1.0);
    check(host4.field("peer") == "-" && host4.field("rejected") != "0", "nor on the guest alone");
}

void test_hello() {
    std::puts("hello:");
    FakeNet net;
    const relay::Ini mine{{"pvp", "On"}, {"coopenemyhealth", "150"}, {"revive", "2 min"}, {"role", "host"}};
    const relay::Ini theirs{{"pvp", "Off"}, {"coopenemyhealth", "150"}, {"revive", "2 min"}, {"role", "guest"}};
    End host(net, "host", 1, std::nullopt, mine), guest(net, "client", 2, at(1), theirs);
    host.box.post_map("Map_Village");
    run(net, {&host, &guest}, 0.3);
    check(host.field("mismatch") == "pvp" && guest.field("mismatch") == "pvp", "a shared setting that differs is reported, on both sides, and nothing else");
    check(host.field("partner_version") == "1.5.0", "the partner's version arrives");
    check(guest.field("partner_map") == "Map_Village", "and its map");

    RawHeader h;
    std::string section;
    relay::Writer w(section);
    w.put<uint8_t>(relay::SEC_HELLO);
    w.text("1 time=999\nconnected=yes\npvp=on connected=yes\n");
    FakeNet alone;
    End listener(alone, "host", 1, std::nullopt, {{"pvp", "off"}});
    listener.relay->handle(at(2), raw_packet(h, section), alone.now);
    const std::string status = listener.status();
    size_t connected = 0;
    for (size_t at_ = status.find("connected="); at_ != std::string::npos; at_ = status.find("connected=", at_ + 1)) connected++;
    check(connected == 1 && status.find('\n') == std::string::npos && status.find("time=999") == std::string::npos, "a partner's values can't write into the status line");

    FakeNet old;
    End host2(old, "host", 1);
    const std::string json = "{\"v\":2,\"t\":\"ping\"}";
    old.send(at(2), host2.addr, json);
    run(old, {&host2}, 0.1);
    check(host2.field("partner_version") == "1.4.1-or-older", "a 1.4.1 JSON packet is reported as an old partner");
    check(host2.field("peer") == "-", "and isn't taken as one");
    RawHeader other_protocol;
    std::string future = raw_packet(other_protocol);
    future[1] = relay::PROTOCOL + 1;
    old.send(at(2), host2.addr, future);
    run(old, {&host2}, 0.1);
    check(host2.field("partner_version") == "other-protocol", "another protocol is reported too");

    End guest2(old, "client", 3, at(1));
    run(old, {&host2, &guest2}, 2.5);
    old.send(at(9), host2.addr, json);
    run(old, {&host2, &guest2}, 0.1);
    check(host2.field("partner_version") == "1.5.0", "a stranger's old packet says nothing about the partner");
}

void test_wire() {
    std::puts("on the wire:");
    {
        FakeNet net;
        net.dup = 1;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        for (int i = 0; i < 200; i++) {
            host.box.post_sure("h" + std::to_string(i) + " x");
            guest.box.post_sure("g" + std::to_string(i) + " x");
            host.box.post_quick("q" + std::to_string(i) + " x");
            run(net, {&host, &guest}, 0.03);
        }
        run(net, {&host, &guest}, 1.0);
        check(in_order(guest.events, "h", 200) && in_order(host.events, "g", 200), "every packet twice: sure events once each");
        check(in_order(guest.events, "q", 200), "and quick events too");
    }
    {
        FakeNet net;
        net.jitter = 0.12;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.5);
        for (int i = 0; i < 300; i++) {
            host.box.post_sure("h" + std::to_string(i) + " x");
            guest.box.post_sure("g" + std::to_string(i) + " x");
            run(net, {&host, &guest}, 0.01);
        }
        run(net, {&host, &guest}, 1.5);
        check(in_order(guest.events, "h", 300) && in_order(host.events, "g", 300), "every packet up to 120 ms late, so out of order: sure events in order");
    }
    {
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        host.box.post_sure(std::string(relay::MAX_TEXT, 'm'));
        host.box.post_sure(std::string(70000, 'b'));
        host.box.post_quick(std::string(relay::MAX_TEXT, 'q'));
        host.box.post_enemy(std::string(relay::MAX_TEXT, 'e'));
        host.box.post_map(std::string(4000, 'n'));
        run(net, {&host, &guest}, 0.3);
        check(guest.count(std::string(relay::MAX_TEXT, 'm')) == 1, "the longest event arrives whole");
        check(guest.count(std::string(relay::MAX_TEXT, 'b')) == 1, "a longer one is cut to fit, and doesn't stop the lane");
        check(guest.count(std::string(relay::MAX_TEXT, 'q')) == 1 && !guest.box.take_enemies().empty(), "and the same for a quick event and an enemy line");
        check(net.biggest <= relay::MAX_PACKET, "no packet over the limit (" + std::to_string(net.biggest) + " bytes)");
    }
    for (const double loss : {0.0, 0.3}) {
        FakeNet net;
        net.delay = 0.02;
        net.jitter = 0.02;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.5);
        net.loss = loss;
        const int burst = 500;
        for (int i = 0; i < burst; i++) {
            host.box.post_sure(padded("h", i, relay::MAX_TEXT));
            guest.box.post_sure(padded("g", i, relay::MAX_TEXT));
        }
        double took = 0;
        while (took < 30 && !(in_order(guest.events, "h", burst) && in_order(host.events, "g", burst))) {
            run(net, {&host, &guest}, 0.1);
            took += 0.1;
        }
        check(took < 30, "500 of the longest events at once, both ways, " + std::to_string(static_cast<int>(loss * 100)) + "% loss: all in order, in " + std::to_string(took).substr(0, 4) + " s");
        check(net.biggest <= relay::MAX_PACKET, "still no packet over the limit");
    }
    {
        // The game thread stuck in a load: the inbox fills, and what doesn't fit must not be confirmed and lost.
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        guest.reading = false;
        const int total = 2000;
        for (int i = 0; i < total; i++) host.box.post_sure(padded("h", i, relay::MAX_TEXT));
        run(net, {&host, &guest}, 5);
        check(host.field("pending") != "0", "an inbox that's full is not acknowledged");
        guest.reading = true;
        double took = 0;
        while (took < 10 && !in_order(guest.events, "h", total)) {
            run(net, {&host, &guest}, 0.1);
            took += 0.1;
        }
        check(in_order(guest.events, "h", total), "and everything arrives once the game reads again");
    }
    {
        // The header's sequence wraps at 65536: no packet is lost across it, and a real gap is counted right.
        FakeNet net;
        End host(net, "host", 1);
        RawHeader h;
        for (int i = 65530; i < 65546; i++) {
            h.sequence = static_cast<uint16_t>(i);
            host.relay->on_packet(at(2), raw_packet(h), net.now);
        }
        check(host.field("loss_pct") == "0.0", "the sequence wraps at 65536 with nothing counted lost");
        End other(net, "host", 3);
        for (const int sequence : {65533, 65534, 2}) {
            h.sequence = static_cast<uint16_t>(sequence);
            other.relay->on_packet(at(2), raw_packet(h), net.now);
        }
        check(other.field("loss_pct") == "50.0", "and three packets lost across the wrap count as three, not 65000");
    }
    {
        // A real connection through the wrap, both ways, while events flow.
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        int sent = 0;
        for (; net.carried < 140000; sent++) {
            host.box.post_sure("h" + std::to_string(sent) + " x");
            host.box.post_quick("q");
            run(net, {&host, &guest}, 0.02);
        }
        run(net, {&host, &guest}, 0.5);
        check(in_order(guest.events, "h", sent) && host.field("connected") == "yes", "a session past 65536 packets each way keeps working");
    }
}

void test_sessions() {
    std::puts("session numbers:");
    // relay_cli test can only see a process's first session here: a Relay in this process has always had a last one.
    const uint64_t high = 1793540568000ull;      // a real clock reading: the low 32 bits have the top bit set
    const uint64_t low = 1792000000000ull;       // and one where they don't
    check(static_cast<uint32_t>(high) >> 31 == 1 && relay::next_session(0, high) == static_cast<uint32_t>(high), "a process's first session comes from the clock, top bit set");
    check(static_cast<uint32_t>(low) >> 31 == 0 && relay::next_session(0, low) == static_cast<uint32_t>(low), "and with it clear");
    check(relay::next_session(0, high) != relay::next_session(0, high + 10000), "two processes ten seconds apart differ");
    const uint32_t first = relay::next_session(0, high);
    check(relay::next_session(first, high + 500) == first + 500, "a later session is later on the clock");
    check(relay::next_session(first, high) == first + 1, "two in the same millisecond still move on");
    check(relay::next_session(first, high - 3600000) == first + 1, "and so does one after the clock was put back");
    check(relay::next_session(0xFFFFFFFFu, 5ull << 32 | 5) == 5, "the 32-bit circle wraps");
    check(relay::next_session(0, 7ull << 32) == 1, "0 is never a session");
    check(relay::next_session(0xFFFFFFFFu, 0xFFFFFFFFull) == 1, "not even by counting up to it");

    // A second relay at the same address, as a process coming back on the host's port: it must be a new partner.
    FakeNet net;
    End guest(net, "client", 2, at(1));
    {
        End first_host(net, "host", 1);
        first_host.box.post_map("One");
        run(net, {&first_host, &guest}, 0.3);
    }
    net.wires.clear();
    run(net, {&guest}, 4);
    End second_host(net, "host", 1);
    run(net, {&second_host, &guest}, 0.5);
    second_host.box.post_sure("again");
    guest.box.post_sure("heard");
    run(net, {&second_host, &guest}, 0.3);
    check(guest.count("S") == 2 && guest.count("again") == 1 && second_host.count("heard") == 1, "a host back on the same port is a new start, both ways");

    // A sender that pinned the host and left a made-up session behind, far ahead of the real guest's: once it's silent the
    // real one is taken at once, not after waiting out that number.
    FakeNet pinned;
    End host(pinned, "host", 1);
    RawHeader junk;
    junk.session = static_cast<uint32_t>(static_cast<uint64_t>(relay::wall_seconds() * 1000)) + 0x10000000u;
    host.relay->on_packet(at(9), raw_packet(junk), pinned.now);
    check(host.field("peer") == "pc9", "a fake sender can pin an empty host");
    run(pinned, {&host}, relay::PEER_TIMEOUT + 0.1);
    End late(pinned, "client", 2, at(1));
    run(pinned, {&host, &late}, 0.3);
    late.box.post_sure("from the real one");
    run(pinned, {&host, &late}, 0.3);
    check(host.field("connected") == "yes" && host.count("from the real one") == 1, "a made-up session doesn't keep the real guest out");
}

void test_restarts() {
    std::puts("restarts:");
    for (int side = 0; side < 2; side++) {
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        End& leaver = side ? guest : host;
        End& stayer = side ? host : guest;
        const std::string who = side ? "the guest" : "the host";
        run(net, {&host, &guest}, 0.3);
        for (int i = 0; i < 20; i++) {
            leaver.box.post_sure("a" + std::to_string(i) + " x");
            stayer.box.post_sure("b" + std::to_string(i) + " x");
        }
        run(net, {&host, &guest}, 0.3);
        leaver.box.reset();
        run(net, {&host, &guest}, 0.3);
        check(stayer.count("S") == 2, who + " restarts: the other side's game hears of it once");
        check(leaver.count("S") == 1, "and it doesn't hear it from itself");
        leaver.box.post_sure("later1");
        stayer.box.post_sure("later2");
        run(net, {&host, &guest}, 0.3);
        check(stayer.count("later1") == 1 && leaver.count("later2") == 1, "both lanes work from 1 again, both ways");
        check(in_order(stayer.events, "a", 20), "and nothing from before is sent twice");
    }
    {
        // The host restarts while its old packets are still on the way, and they land after the first new ones.
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        net.hold_from = 1;
        for (int i = 0; i < 5; i++) host.box.post_sure("old" + std::to_string(i));
        run(net, {&host, &guest}, 0.2);
        host.box.reset();
        run(net, {&host}, 0.01);
        std::vector<std::pair<uint32_t, FakeNet::Packet>> old = std::move(net.held);
        net.held.clear();
        net.hold_from = 0;
        run(net, {&host, &guest}, relay::KEEPALIVE_EVERY + 0.1);
        for (int i = 0; i < 5; i++) {
            host.box.post_sure("new" + std::to_string(i) + " x");
            guest.box.post_sure("back" + std::to_string(i) + " x");
        }
        run(net, {&host, &guest}, 0.3);
        check(in_order(guest.events, "new", 5) && in_order(host.events, "back", 5), "new events both ways before the old packets land");
        const int restarts = guest.count("S");
        net.held = std::move(old);
        net.let_go();
        run(net, {&host, &guest}, 0.3);
        check(guest.count("S") == restarts, "a packet of the session before isn't a restart");
        check(guest.count("old0") == 0, "its events are nobody's");
        for (int i = 5; i < 25; i++) {
            host.box.post_sure("new" + std::to_string(i) + " x");
            guest.box.post_sure("back" + std::to_string(i) + " x");
        }
        run(net, {&host, &guest}, 0.5);
        check(in_order(guest.events, "new", 25) && in_order(host.events, "back", 25), "and no event is lost or repeated after them");
    }
    {
        // The partner resets twice close together, and packets of the second session land before those of the first,
        // which this side has never seen. A random number could not be told from a third, newer start.
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        const int before = guest.count("S");
        net.hold_from = 1;
        host.box.reset();
        host.box.post_sure("middle");
        run(net, {&host, &guest}, 0.05);
        std::vector<std::pair<uint32_t, FakeNet::Packet>> middle = std::move(net.held);
        net.held.clear();
        net.hold_from = 0;
        host.box.reset();
        run(net, {&host, &guest}, relay::KEEPALIVE_EVERY + 0.1);
        check(!middle.empty() && guest.count("S") == before + 1, "two resets close together: the newest session is heard first, one S");
        net.held = std::move(middle);
        net.let_go();
        run(net, {&host, &guest}, 0.3);
        check(guest.count("S") == before + 1, "the session in between lands late: no flip back, no second S");
        check(guest.count("middle") == 0, "and its events are nobody's");
        host.box.post_sure("n0 x");
        guest.box.post_sure("m0 x");
        run(net, {&host, &guest}, 0.3);
        check(guest.count("n0 x") == 1 && host.count("m0 x") == 1, "both lanes work on the newest session");
    }
    {
        // The same with the network choosing: any mix of the three sessions' packets, either side resetting. Following
        // the wrong session would stop the lanes, and a flip back and forth would show as more S than resets.
        int worst_s = 0, stuck = 0;
        constexpr int runs = 300;
        for (int seed = 1; seed <= runs; seed++) {
            FakeNet net;
            net.rng.seed(seed);
            net.loss = 0.1;
            net.dup = 0.1;
            net.jitter = 0.2;
            End host(net, "host", 1), guest(net, "client", 2, at(1));
            run(net, {&host, &guest}, 1);
            End& leaver = seed % 2 ? host : guest;
            End& stayer = seed % 2 ? guest : host;
            const int before = stayer.count("S");
            leaver.box.reset();
            leaver.box.post_sure("first reset");
            run(net, {&host, &guest}, 0.005 * (seed % 12));
            leaver.box.reset();
            run(net, {&host, &guest}, 2);
            worst_s = std::max(worst_s, stayer.count("S") - before);
            host.events.clear();
            guest.events.clear();
            for (int i = 0; i < 20; i++) {
                host.box.post_sure("h" + std::to_string(i) + " x");
                guest.box.post_sure("g" + std::to_string(i) + " x");
            }
            run(net, {&host, &guest}, 2);
            if (!in_order(guest.events, "h", 20) || !in_order(host.events, "g", 20)) stuck++;
        }
        check(worst_s <= 2, "300 double resets through heavy reordering: never more S than resets (at most " + std::to_string(worst_s) + ")");
        check(stuck == 0, "and each time both lanes end up on the newest session (" + std::to_string(stuck) + " stuck)");
    }
    {
        // Sure events flowing through a restart at 30% loss, then the guest's turn.
        FakeNet net;
        net.loss = 0.3;
        net.delay = 0.02;
        net.jitter = 0.03;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 1);
        bool ok = true;
        for (int round = 0; round < 6; round++) {
            End& leaver = round % 2 ? guest : host;
            End& stayer = round % 2 ? host : guest;
            leaver.box.reset();
            const int seen = stayer.count("S");
            for (double t = 0; t < 5 && stayer.count("S") == seen; t += 0.05) run(net, {&host, &guest}, 0.05);
            run(net, {&host, &guest}, 0.5);
            host.events.clear();
            guest.events.clear();
            for (int i = 0; i < 40; i++) {
                host.box.post_sure("h" + std::to_string(i) + " x");
                guest.box.post_sure("g" + std::to_string(i) + " x");
                run(net, {&host, &guest}, 0.02);
            }
            run(net, {&host, &guest}, 2.5);
            ok = ok && in_order(guest.events, "h", 40) && in_order(host.events, "g", 40);
        }
        check(ok, "six restarts in turn at 30% loss: the lanes come back whole every time");
    }
    {
        // A partner lost to a corrupt packet with a made-up session comes back by itself.
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        RawHeader bad;
        bad.session = 0x12345678;
        host.relay->on_packet(guest.addr, raw_packet(bad), net.now);
        run(net, {&host, &guest}, relay::SESSION_RETIRED_S + 1);
        host.box.post_sure("still here");
        guest.box.post_sure("me too");
        run(net, {&host, &guest}, 0.5);
        check(guest.count("still here") == 1 && host.count("me too") == 1, "a corrupt session doesn't lock the real partner out");
    }
}

void test_silence() {
    std::puts("long silence:");
    {
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        net.down = true;
        for (int i = 0; i < 2000; i++) {
            host.box.post_sure(padded("h", i, 200));
            run(net, {&host, &guest}, 0.03);
        }
        const long long before = net.carried;
        run(net, {&host, &guest}, 60);
        const long long sent = net.carried - before;
        check(sent < 2 * 60 * 6, "a minute with nobody there is keepalives, not resends (" + std::to_string(sent) + " packets)");
        check(host.field("connected") == "no", "and shows as not connected");
        net.down = false;
        run(net, {&host, &guest}, 1);
        check(host.field("connected") == "yes", "the partner is back");
        check(in_order(guest.events, "h", 2000), "with every event, in order");
        check(guest.count("S") == 1, "and it isn't a restart");
        host.box.post_sure("after");
        run(net, {&host, &guest}, 0.2);
        check(guest.count("after") == 1, "and new events flow");
    }
    {
        // Away long enough that the queue dropped events. Numbers can't cross that hole: both sides start over.
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        net.down = true;
        run(net, {&host, &guest}, 4);
        for (int i = 0; i < 2; i++) {
            for (size_t n = 0; n < relay::MAX_SURE_PENDING; n++) host.box.post_sure("x");
            run(net, {&host, &guest}, 0.05);
        }
        run(net, {&host, &guest}, 10);
        check(host.count("S") == 1, "while the partner is away nothing happens yet");
        net.down = false;
        run(net, {&host, &guest}, 1);
        check(host.count("S") == 2 && guest.count("S") == 2, "a queue that overflowed starts both sides over, and both games hear it");
        host.box.post_sure("after");
        guest.box.post_sure("back");
        run(net, {&host, &guest}, 0.5);
        check(guest.count("after") == 1 && host.count("back") == 1, "and the sure lane isn't stuck behind the hole");
    }
    {
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        for (int i = 0; i < 3000; i++) {
            host.box.post_quick("q");
            run(net, {&host}, 0.01);
        }
        run(net, {&host}, relay::QUICK_MAX_AGE_S + 0.1);
        run(net, {&host, &guest}, 0.3);
        check(guest.count("q") == 0, "moves made well before the partner joined are never played");
    }
}

// Packets against the end of readable memory: reading one byte too far is a crash here, not silently a wrong value.
class EdgeOfMemory {
public:
    EdgeOfMemory() {
        SYSTEM_INFO info;
        GetSystemInfo(&info);
        page_ = info.dwPageSize;
        total_ = (SIZE + page_ - 1) / page_ * page_;
        base_ = static_cast<char*>(VirtualAlloc(nullptr, total_ + page_, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
        DWORD before;
        VirtualProtect(base_ + total_, page_, PAGE_NOACCESS, &before);
    }
    ~EdgeOfMemory() { VirtualFree(base_, 0, MEM_RELEASE); }

    std::string_view place(std::string_view data) {
        data = data.substr(0, SIZE);
        char* at = base_ + total_ - data.size();
        std::memcpy(at, data.data(), data.size());
        return {at, data.size()};
    }

private:
    static constexpr size_t SIZE = 1 << 17;
    char* base_ = nullptr;
    size_t page_ = 0, total_ = 0;
};

// One of each section, as big as they get.
std::string every_section(const RawHeader& h) {
    relay::Sample s;
    s.ms = 5000;
    s.hp = 100;
    s.max_hp = 100;
    std::string rest;
    relay::Writer w(rest);
    w.put<uint8_t>(relay::SEC_STATE);
    relay::put_sample(w, s);
    w.put<uint8_t>(relay::SEC_SURE);
    w.put<uint32_t>(1);
    w.text("sure event");
    w.put<uint8_t>(relay::SEC_QUICK);
    w.put<uint32_t>(1);
    w.put<uint16_t>(0);
    w.text("quick event");
    w.put<uint8_t>(relay::SEC_ENEMY);
    w.text("1 2 3 4 5 6 7 8 9 0 1");
    w.put<uint8_t>(relay::SEC_HELLO);
    w.text("1.5.0\nMap\npvp=on\n");
    return raw_packet(h, rest);
}

void test_hostile() {
    std::puts("broken and hostile packets:");
    EdgeOfMemory edge;
    FakeNet net;
    End host(net, "host", 1), guest(net, "client", 2, at(1));
    run(net, {&host, &guest}, 0.3);
    RawHeader h;
    h.session = 0x51515151;
    const std::string whole = every_section(h);
    for (size_t n = 0; n <= whole.size(); n++) host.relay->handle(guest.addr, edge.place(std::string_view(whole).substr(0, n)), net.now);
    check(true, "a packet of every section cut at each of its " + std::to_string(whole.size()) + " bytes: no crash, no read past the end");

    std::mt19937 rng(20261101);
    const auto byte = [&] { return static_cast<char>(rng() & 255); };
    const int rounds = 2000000;
    double now = net.now;
    relay::Sample out;
    double silence, delay;
    bool finite = true;
    for (int i = 0; i < rounds; i++) {
        std::string p;
        const int kind = i % 5;
        if (kind == 0) {                                    // noise, any length
            p.resize(rng() % 1400);
            for (char& c : p) c = byte();
        } else if (kind == 1) {                             // noise behind the right marker
            p = raw_packet(h);
            p.resize(p.size() + rng() % 1000);
            for (size_t n = 31; n < p.size(); n++) p[n] = byte();
        } else if (kind == 2) {                             // a good packet with a few wrong bytes
            h.sequence++;
            p = every_section(h);
            for (uint32_t n = 1 + rng() % 8; n > 0; n--) p[rng() % p.size()] = byte();
        } else if (kind == 3) {                             // the same, cut short too
            p = every_section(h);
            p[31 + rng() % (p.size() - 31)] = byte();
            p.resize(rng() % p.size());
        } else {                                            // lengths that claim more than there is
            RawHeader lying = h;
            lying.session = rng() % 4 ? h.session : rng();
            std::string rest;
            relay::Writer w(rest);
            const uint8_t section = static_cast<uint8_t>(1 + rng() % 6);
            w.put<uint8_t>(section);
            if (section == relay::SEC_SURE || section == relay::SEC_QUICK) w.put<uint32_t>(rng());
            if (section == relay::SEC_QUICK) w.put<uint16_t>(0);
            w.put<uint16_t>(static_cast<uint16_t>(rng()));
            rest.resize(rest.size() + rng() % 64, 'a');
            p = raw_packet(lying, rest);
        }
        host.relay->handle(guest.addr, edge.place(p), now);
        if (i % 512 == 0) {
            now += 0.001;
            net.now = now;
            host.step();
            host.events.clear();
            host.box.take_enemies();
            if (host.box.partner(relay::clock_ms(), out, silence, delay))
                finite = finite && std::isfinite(out.x) && std::isfinite(out.y) && std::isfinite(out.z) && std::isfinite(out.yaw) && std::isfinite(out.hp);
        }
    }
    check(true, std::to_string(rounds) + " garbage packets from one sender: no crash, no read past the end");
    check(finite, "nothing that isn't a number reached the game");

    run(net, {&host, &guest}, relay::SESSION_RETIRED_S + 1);
    host.box.post_sure("alive");
    guest.box.post_sure("alive too");
    run(net, {&host, &guest}, 1);
    check(guest.count("alive") == 1 && host.count("alive too") == 1, "and the real partner still gets through");

    const std::string secret = "correct horse battery";
    FakeNet signed_net;
    End strict(signed_net, "host", 1, std::nullopt, {}, &secret);
    for (int i = 0; i < 100000; i++) {
        std::string p(relay::Auth::HEADER + relay::Auth::TAG + rng() % 256, '\0');
        for (char& c : p) c = byte();
        if (i % 2) p.replace(0, 4, relay::Auth::MAGIC, 4);
        strict.relay->on_packet(at(2), p, signed_net.now);
    }
    check(strict.field("rejected") == "100000" && strict.field("peer") == "-", "with a secret, none of 100000 forgeries even gets looked at");

    // Sample values a real game never sends must stop at the door.
    FakeNet net2;
    End taker(net2, "host", 1);
    RawHeader first;
    const auto with_sample = [&](float x, float hp) {
        relay::Sample s;
        s.ms = 5000;
        s.x = x;
        s.hp = hp;
        std::string rest;
        relay::Writer w(rest);
        w.put<uint8_t>(relay::SEC_STATE);
        relay::put_sample(w, s);
        return raw_packet(first, rest);
    };
    taker.relay->handle(at(2), with_sample(std::numeric_limits<float>::quiet_NaN(), 1), net2.now);
    taker.relay->handle(at(2), with_sample(3e38f, 1), net2.now);
    taker.relay->handle(at(2), with_sample(0, std::numeric_limits<float>::infinity()), net2.now);
    check(!taker.box.partner(relay::clock_ms(), out, silence, delay), "a sample with a position or health that isn't sane is dropped");
    const std::string counted = taker.field("received");
    RawHeader zero;
    zero.session = 0;
    taker.relay->handle(at(2), raw_packet(zero), net2.now);
    check(taker.field("received") == counted, "session 0 is nobody");
}

// A host with FourPlayers = On, in the same simulated network as End.
struct Hosting {
    Hosting(FakeNet& net, uint32_t ip, const std::string* secret = nullptr)
        : addr(at(ip)), net_(net), party(L".", std::make_unique<FakeLink>(net, addr, std::nullopt, std::vector<relay::Addr>{}), secret, {}, "1.5.0",
                                         [](const std::string&) {}, box) {}

    void step() {
        party.tick(net_.now);
        if (reading) split_lines(box.take_events(relay::clock_ms()), events);
    }

    std::string field(const std::string& key) {
        const std::string line = " " + party.status(net_.now) + " ", tag = " " + key + "=";
        const size_t from = line.find(tag);
        if (from == std::string::npos) return "";
        const size_t start = from + tag.size();
        return line.substr(start, line.find(' ', start) - start);
    }

    int count(const std::string& line) const { return static_cast<int>(std::count(events.begin(), events.end(), line)); }

    relay::Mailbox box;
    relay::Addr addr;
    FakeNet& net_;
    relay::Party party;
    std::vector<std::string> events;
    bool reading = true;
};

void run(FakeNet& net, Hosting& host, std::initializer_list<End*> ends, double seconds) {
    for (double t = 0; t < seconds; t += 0.005) {
        net.now += 0.005;
        host.step();
        for (End* e : ends) e->step();
    }
}

// The same player seen from another PC: where they are, or nothing.
bool sees(relay::Mailbox& box, int slot, relay::Sample& out) {
    double silence = 0, delay = 0;
    return box.player(slot, relay::clock_ms(), out, silence, delay);
}

relay::Sample at_x(float x) {
    relay::Sample s;
    s.ms = static_cast<uint32_t>(relay::clock_ms());
    s.x = x;
    s.hp = 100;
    s.max_hp = 100;
    return s;
}

int slot_of(End& guest) {
    int players = 0, slot = 0;
    guest.box.party(players, slot);
    return slot;
}

void test_party() {
    std::puts("four players:");
    {
        FakeNet net;
        Hosting host(net, 1);
        End a(net, "client", 2, at(1)), b(net, "client", 3, at(1)), c(net, "client", 4, at(1));
        run(net, host, {&a, &b, &c}, 0.5);
        check(host.field("guests") == "3" && a.field("connected") == "yes" && c.field("connected") == "yes", "three guests on one host");
        check(a.field("slot") == "2" && b.field("slot") == "3" && c.field("slot") == "4" && a.field("players") == "4", "each is told its own slot, in the order they came");
        int players = 0, slot = 0;
        check(host.box.party(players, slot) && players == 4 && slot == 1, "and the host's game knows it's a party");
        check(host.count("@2 S") == 1 && host.count("@3 S") == 1 && host.count("@4 S") == 1 && host.count("S") == 0, "the host hears each one's start once, by slot");

        host.box.post_sure("from host");
        host.box.post_quick("quick host");
        host.box.post_enemy("1 2 3");
        host.box.post_sample(at_x(500));
        host.box.post_map("Map_Xigu");
        run(net, host, {&a, &b, &c}, 0.3);
        relay::Sample out;
        double silence, delay;
        bool everyone = true;
        for (End* g : {&a, &b, &c}) {
            everyone = everyone && g->count("from host") == 1 && g->count("quick host") == 1 && !g->box.take_enemies().empty() &&
                       g->box.partner(relay::clock_ms(), out, silence, delay) && out.x > 400 && g->field("partner_map") == "Map_Xigu";
        }
        check(everyone, "what the host does reaches all three: events, moves, enemies, position, map");

        a.box.post_sample(at_x(1000));
        b.box.post_sample(at_x(2000));
        c.box.post_sample(at_x(3000));
        run(net, host, {&a, &b, &c}, 0.3);
        check(sees(host.box, 2, out) && out.x == 1000 && sees(host.box, 3, out) && out.x == 2000 && sees(host.box, 4, out) && out.x == 3000, "the host sees each guest in its own slot");
        check(sees(a.box, 3, out) && out.x == 2000 && sees(a.box, 4, out) && out.x == 3000, "a guest sees the other two through the host");
        check(sees(b.box, 2, out) && out.x == 1000 && sees(c.box, 3, out) && out.x == 2000, "and so do the others");
        check(!sees(a.box, 2, out) && !sees(b.box, 3, out) && !sees(c.box, 4, out), "nobody gets their own position back");
        check(a.box.partner(relay::clock_ms(), out, silence, delay) && out.x == 500, "a guest's partner stays the host");

        a.box.post_sure("O chest1");
        a.box.post_quick("U move 0");
        run(net, host, {&a, &b, &c}, 0.3);
        check(host.count("@2 O chest1") == 1 && b.count("@2 O chest1") == 1 && c.count("@2 O chest1") == 1, "a guest's event reaches everyone, with who sent it");
        check(a.count("@2 O chest1") == 0 && a.count("O chest1") == 0, "but doesn't come back to the sender");
        check(host.count("@2 U move 0") == 1 && b.count("@2 U move 0") == 1 && c.count("@2 U move 0") == 1, "the same for a move");

        a.box.post_sure("D sp:boss 10.0 2.0 -");
        a.box.post_sure("GK sp:far");
        run(net, host, {&a, &b, &c}, 0.3);
        check(host.count("@2 D sp:boss 10.0 2.0 -") == 1 && b.count("@2 D sp:boss 10.0 2.0 -") == 0 && c.count("@2 D sp:boss 10.0 2.0 -") == 0, "a hit goes to the host alone");
        check(host.count("@2 GK sp:far") == 1 && b.count("@2 GK sp:far") == 1 && c.count("@2 GK sp:far") == 1, "a kill on a copy the host hasn't loaded reaches everyone");

        host.box.post_to(3, "K only for b");
        run(net, host, {&a, &b, &c}, 0.3);
        check(b.count("K only for b") == 1 && a.count("K only for b") == 0 && c.count("K only for b") == 0, "the host can tell one guest alone");
        host.box.post_to(7, "K nobody");
        host.box.post_to(0, "K nobody");
        run(net, host, {&a, &b, &c}, 0.1);
        check(a.count("K nobody") + b.count("K nobody") + c.count("K nobody") == 0, "a slot that doesn't exist reaches nobody");

        // A fifth player is turned away and nobody else notices.
        End d(net, "client", 5, at(1));
        run(net, host, {&a, &b, &c, &d}, 1.0);
        check(d.field("connected") == "no" && host.field("turned_away") != "0", "a fourth guest gets no answer, and the host counts it");
        check(host.field("guests") == "3" && slot_of(d) == 0, "and takes nobody's place");
        a.box.post_sure("still fine");
        run(net, host, {&a, &b, &c, &d}, 0.3);
        check(b.count("@2 still fine") == 1 && d.count("@2 still fine") == 0, "the three go on");

        // One goes quiet: the others are untouched, and the slot passes to the one who was waiting.
        run(net, host, {&a, &c, &d}, relay::PEER_TIMEOUT + 0.5);
        check(host.field("guests") == "3" && slot_of(d) == 3, "a guest gone silent frees its slot for the next");
        check(host.count("@3 S") == 2, "the host's game hears of the new player in that slot");
        a.box.post_sure("for the new one");
        d.box.post_sure("from the new one");
        run(net, host, {&a, &c, &d}, 0.3);
        check(d.count("@2 for the new one") == 1 && a.count("@3 from the new one") == 1 && host.count("@3 from the new one") == 1, "and the lanes work with them");

        // A guest restarts: only its own connection starts over.
        const int events_a = a.count("@3 from the new one");
        c.box.reset();
        run(net, host, {&a, &c, &d}, 0.3);
        check(host.count("@4 S") == 2, "a guest's restart is heard once");
        check(a.field("connected") == "yes" && a.count("S") == 1 && d.count("S") == 1, "and doesn't restart anyone else");
        check(a.count("@3 from the new one") == events_a, "or play anything twice");

        // The host restarts: everyone hears it.
        host.box.reset();
        run(net, host, {&a, &c, &d}, 0.3);
        check(a.count("S") == 2 && c.count("S") == 2 && d.count("S") == 2, "a host's restart reaches every guest");
        host.box.post_sure("after the restart");
        c.box.post_sure("guest after");
        run(net, host, {&a, &c, &d}, 0.3);
        check(a.count("after the restart") == 1 && d.count("after the restart") == 1 && a.count("@4 guest after") == 1, "and all the lanes work from 1 again");
    }
    {
        // Each guest counts, not only the one who speaks for the connection.
        FakeNet net;
        Hosting host(net, 1);
        const relay::Ini same{{"pvp", "off"}}, differs{{"pvp", "on"}, {"coopenemyhealth", "300"}};
        End a(net, "client", 2, at(1), same), b(net, "client", 3, at(1), differs);
        a.box.post_map("Map_A");
        b.box.post_map("Map_B");
        run(net, host, {&a, &b}, 0.3);
        host.box.post_sample(at_x(1));
        check(host.field("guests") == "2" && host.field("map2") == "Map_A" && host.field("map3") == "Map_B", "the host's status names each guest's map");
        check(host.field("other_versions").empty(), "and says nothing of versions while they match");
        for (int i = 0; i < 100; i++) {
            host.box.post_sample(at_x(1));
            run(net, host, {&a, &b}, 0.02);
        }
        check(host.field("upload_kb_s").find_first_not_of("0123456789") == std::string::npos, "and what it sends a second");
        FakeNet other;
        Hosting mixed(other, 1);
        const relay::Ini host_ini{{"pvp", "off"}};
        End first(other, "client", 2, at(1));
        relay::Mailbox box;
        // A guest on another version of the mod, whichever slot it lands in.
        auto oddLink = std::make_unique<FakeLink>(other, at(3), at(1), std::vector<relay::Addr>{});
        relay::Relay odd("client", L".", std::move(oddLink), nullptr, {}, "1.4.1b", [](const std::string&) {}, box);
        for (int i = 0; i < 100; i++) {
            other.now += 0.005;
            mixed.step();
            first.step();
            odd.tick(other.now);
        }
        check(mixed.field("other_versions") == "3:1.4.1b", "a guest on another version is named, though another guest speaks for the connection");
    }
    {
        // A setting that differs on one guest shows on the host, whoever speaks for the connection.
        FakeNet net;
        relay::Mailbox box;
        relay::Party party(L".", std::make_unique<FakeLink>(net, at(1), std::nullopt, std::vector<relay::Addr>{}), nullptr, {{"pvp", "off"}}, "1.5.0", [](const std::string&) {}, box);
        End a(net, "client", 2, at(1), {{"pvp", "off"}}), b(net, "client", 3, at(1), {{"pvp", "on"}});
        for (int i = 0; i < 100; i++) {
            net.now += 0.005;
            party.tick(net.now);
            a.step();
            b.step();
        }
        const std::string line = party.status(net.now);
        check(line.find(" mismatch=pvp ") != std::string::npos, "a setting that differs on the second guest is reported");
    }
    {
        // Every lane between every pair at once, through a bad connection.
        FakeNet net;
        net.delay = 0.02;
        net.jitter = 0.02;
        Hosting host(net, 1);
        End a(net, "client", 2, at(1)), b(net, "client", 3, at(1)), c(net, "client", 4, at(1));
        run(net, host, {&a, &b, &c}, 0.5);
        net.loss = 0.3;
        const int total = 300;
        double took = 0;
        for (int i = 0; i < total; i++) {
            host.box.post_sure("h" + std::to_string(i) + " x");
            a.box.post_sure("a" + std::to_string(i) + " x");
            b.box.post_sure("b" + std::to_string(i) + " x");
            c.box.post_sure("c" + std::to_string(i) + " x");
            if (i % 10 == 0) run(net, host, {&a, &b, &c}, 0.01);
        }
        const auto strip = [](const std::vector<std::string>& lines, const std::string& tag) {
            std::vector<std::string> out;
            for (const std::string& line : lines)
                if (line.rfind(tag, 0) == 0) out.push_back(line.substr(tag.size()));
            return out;
        };
        // (They started together on a jittery link, so which of them came first is the network's choice.)
        const std::string from_a = "@" + std::to_string(slot_of(a)) + " ", from_b = "@" + std::to_string(slot_of(b)) + " ", from_c = "@" + std::to_string(slot_of(c)) + " ";
        check(from_a != from_b && from_b != from_c && from_a != from_c && slot_of(a) && slot_of(b) && slot_of(c), "three at once through a jittery link get a slot each");
        const auto done = [&] {
            return in_order(a.events, "h", total) && in_order(b.events, "h", total) && in_order(c.events, "h", total) &&
                   in_order(strip(host.events, from_a), "a", total) && in_order(strip(host.events, from_b), "b", total) && in_order(strip(host.events, from_c), "c", total) &&
                   in_order(strip(b.events, from_a), "a", total) && in_order(strip(c.events, from_a), "a", total) &&
                   in_order(strip(a.events, from_b), "b", total) && in_order(strip(c.events, from_b), "b", total) &&
                   in_order(strip(a.events, from_c), "c", total) && in_order(strip(b.events, from_c), "c", total);
        };
        while (took < 30 && !done()) {
            run(net, host, {&a, &b, &c}, 0.1);
            took += 0.1;
        }
        check(done(), "everyone to everyone at 30% loss: all there, in order, once each, in " + std::to_string(took).substr(0, 4) + " s");
    }
    {
        // Back-pressure runs through the host: with its game stuck in a load, a guest's events wait unconfirmed.
        FakeNet net;
        Hosting host(net, 1);
        End a(net, "client", 2, at(1)), b(net, "client", 3, at(1));
        run(net, host, {&a, &b}, 0.3);
        host.reading = false;
        const int total = 2000;
        for (int i = 0; i < total; i++) a.box.post_sure(padded("a", i, relay::MAX_TEXT));
        run(net, host, {&a, &b}, 5);
        check(a.field("pending") != "0", "a host's inbox that's full isn't acknowledged");
        host.reading = true;
        double took = 0;
        std::vector<std::string> plain;
        const auto got = [&] {
            plain.clear();
            for (const std::string& line : host.events)
                if (line.rfind("@2 a", 0) == 0) plain.push_back(line.substr(3));
            return in_order(plain, "a", total);
        };
        while (took < 10 && !got()) {
            run(net, host, {&a, &b}, 0.1);
            took += 0.1;
        }
        check(got(), "and everything arrives, once, when its game reads again");
        run(net, host, {&a, &b}, 1);
        plain.clear();
        for (const std::string& line : b.events)
            if (line.rfind("@2 a", 0) == 0) plain.push_back(line.substr(3));
        check(in_order(plain, "a", total), "and reaches the other guest once too");
    }
    {
        // What a guest may and may not say.
        FakeNet net;
        Hosting host(net, 1);
        End a(net, "client", 2, at(1)), b(net, "client", 3, at(1));
        run(net, host, {&a, &b}, 0.3);
        a.box.post_sure("@3 C 999999");
        run(net, host, {&a, &b}, 0.3);
        check(host.count("@2 @3 C 999999") == 1 && b.count("@2 @3 C 999999") == 1 && host.count("@3 C 999999") == 0, "a guest can't speak for another: the tag in front is the host's");
        a.box.post_sure("C 1\n@3 C 999999");
        a.box.post_sure("C 2\rK sp:boss");
        a.box.post_quick("U x 0\nK sp:boss");
        a.box.post_sure("after the forgery");
        run(net, host, {&a, &b}, 0.3);
        check(host.count("@3 C 999999") == 0 && b.count("@3 C 999999") == 0 && host.count("K sp:boss") == 0 && b.count("K sp:boss") == 0, "nor with a line break in an event, to anyone");
        check(host.count("@2 after the forgery") == 1 && b.count("@2 after the forgery") == 1, "and its lane goes on behind it");

        relay::Sample s = at_x(7777);
        std::string rest;
        relay::Writer w(rest);
        w.put<uint8_t>(relay::SEC_PLAYER);
        w.put<uint8_t>(3);
        relay::put_sample(w, s);
        RawHeader forged;       // a first packet from a new sender, so every section of it is read
        FakeNet other;
        Hosting empty(other, 1);
        empty.party.on_packet(at(9), raw_packet(forged, rest), other.now);
        relay::Sample out;
        check(empty.field("peer") == "pc9" && !sees(empty.box, 3, out), "a host takes no other player's position from a guest");

        const std::string secret = "correct horse battery", wrong = "something else";
        FakeNet signed_net;
        Hosting strict(signed_net, 1, &secret);
        End good(signed_net, "client", 2, at(1), {}, &secret), bad(signed_net, "client", 3, at(1), {}, &wrong);
        run(signed_net, strict, {&good, &bad}, 1.0);
        check(strict.field("guests") == "1" && good.field("connected") == "yes" && good.field("slot") == "2", "with a Secret the right guest gets in");
        check(bad.field("connected") == "no" && strict.field("rejected") != "0", "and the wrong one takes no slot");
    }
    {
        FakeNet net;
        Hosting host(net, 1);
        End a(net, "client", 2, at(1)), b(net, "client", 3, at(1)), c(net, "client", 4, at(1));
        run(net, host, {&a, &b, &c}, 0.3);
        for (int i = 0; i < 400; i++) {
            host.box.post_sample(at_x(1));
            a.box.post_sample(at_x(2));
            b.box.post_sample(at_x(3));
            c.box.post_sample(at_x(4));
            host.box.post_sure(padded("h", i, relay::MAX_TEXT));
            a.box.post_quick(std::string(relay::MAX_TEXT, 'q'));
            host.box.post_enemy(std::string(relay::MAX_TEXT, 'e'));
            run(net, host, {&a, &b, &c}, 0.017);
        }
        check(net.biggest <= relay::MAX_PACKET, "no packet over the limit with everything at once (" + std::to_string(net.biggest) + " bytes)");
        check(in_order(a.events, "h", 400) && in_order(c.events, "h", 400), "and the sure lane keeps up");
    }
    {
        // The other half of "players=": a guest whose host says nothing is back to two players.
        FakeNet net;
        End guest(net, "client", 2, at(1));
        {
            Hosting party(net, 1);
            run(net, party, {&guest}, 0.3);
            check(slot_of(guest) == 2, "a guest in a party knows it");
        }
        net.wires.clear();
        run(net, {&guest}, 4);
        End plain(net, "host", 1);
        run(net, {&plain, &guest}, relay::HELLO_EVERY + 0.3);
        check(slot_of(guest) == 0 && guest.field("players").empty(), "and a host with two players takes it back");
    }
    {
        // With two players the status line says nothing of any of this.
        FakeNet net;
        End host(net, "host", 1), guest(net, "client", 2, at(1));
        run(net, {&host, &guest}, 0.3);
        int players = 0, slot = 0;
        check(!host.box.party(players, slot) && !guest.box.party(players, slot), "a plain host and guest aren't a party");
        check(host.field("players").empty() && guest.field("players").empty() && guest.field("slot").empty(), "and their status lines don't change");
    }
    {
        // Packets cut at every byte, and noise, at a guest that's listening for other players.
        EdgeOfMemory edge;
        FakeNet net;
        Hosting host(net, 1);
        End a(net, "client", 2, at(1));
        run(net, host, {&a}, 0.3);
        RawHeader h;
        h.flags = relay::FLAG_FROM_HOST;
        h.session = static_cast<uint32_t>(static_cast<uint64_t>(relay::wall_seconds() * 1000)) + 0x10000000u;    // newer: it gets read
        relay::Sample s = at_x(5);
        std::string rest;
        relay::Writer w(rest);
        for (int slot = 0; slot < 8; slot++) {
            w.put<uint8_t>(relay::SEC_PLAYER);
            w.put<uint8_t>(static_cast<uint8_t>(slot));
            relay::put_sample(w, s);
        }
        w.put<uint8_t>(relay::SEC_HELLO);
        w.text("1.5.0\nMap\nplayers=4\nslot=2\nplayers=99999999999999999999\nslot=-1\n");
        const std::string whole = raw_packet(h, rest);
        for (size_t n = 0; n <= whole.size(); n++) a.relay->handle(host.addr, edge.place(std::string_view(whole).substr(0, n)), net.now);
        check(true, "a party's sections cut at each of " + std::to_string(whole.size()) + " bytes: no crash, no read past the end");
        std::mt19937 rng(20261102);
        bool finite = true;
        relay::Sample out;
        for (int i = 0; i < 500000; i++) {
            std::string p = whole;
            for (uint32_t n = 1 + rng() % 8; n > 0; n--) p[31 + rng() % (p.size() - 31)] = static_cast<char>(rng() & 255);
            p.resize(31 + rng() % (p.size() - 30));
            a.relay->handle(host.addr, edge.place(p), net.now);
            p[2] = 0;               // the same from a guest
            host.party.on_packet(a.addr, p, net.now);
            if (i % 512 == 0) {
                for (int slot = 0; slot < 8; slot++)
                    if (sees(a.box, slot, out)) finite = finite && std::isfinite(out.x) && std::isfinite(out.hp);
                a.box.take_events(relay::clock_ms());
                host.box.take_events(relay::clock_ms());
            }
        }
        check(finite, "500000 damaged party packets, both ways: no crash, and nothing that isn't a number reached the game");
    }
}

// Over real UDP sockets on this PC: two relays with threads of their own, as in the game, through a real bad connection.
void sure_over_sockets(int port, double loss_pct, int total, size_t bytes) {
    relay::Mailbox host_box, guest_box;
    const auto quiet = [](const std::string&) {};
    relay::Relay host("host", L".", std::make_unique<relay::UdpLink>("host", "", port, false, true), nullptr, {}, "test", quiet, host_box);
    relay::Relay guest("client", L".", std::make_unique<relay::UdpLink>("client", "127.0.0.1", port + 1, false, true), nullptr, {}, "test", quiet, guest_box);
    Netem bad;
    bad.listen = port + 1;
    bad.target = port;
    bad.delay = 15;
    bad.jitter = 10;
    bad.loss = loss_pct;
    bad.seconds = 90;
    std::atomic<bool> stop{false};
    const auto pump = [&stop](relay::Relay* r) {
        while (!stop) {
            r->tick(monotonic());
            r->wait();
        }
    };
    std::thread wire([&] { netem(bad, &stop); }), a(pump, &host), b(pump, &guest);
    std::vector<std::string> at_host, at_guest;
    const auto read = [&] {
        split_lines(host_box.take_events(relay::clock_ms()), at_host);
        split_lines(guest_box.take_events(relay::clock_ms()), at_guest);
    };
    const auto heard = [](const std::vector<std::string>& v) { return std::count(v.begin(), v.end(), "S") > 0; };
    const double begin = monotonic();
    while (monotonic() - begin < 10 && !(heard(at_host) && heard(at_guest))) {
        read();
        Sleep(5);
    }
    const bool met = heard(at_host) && heard(at_guest);
    for (int i = 0; i < total; i++) {
        host_box.post_sure(padded("h", i, bytes));
        guest_box.post_sure(padded("g", i, bytes));
    }
    const double start = monotonic();
    while (monotonic() - start < 40 && !(in_order(at_guest, "h", total) && in_order(at_host, "g", total))) {
        read();
        Sleep(20);
    }
    const double took = monotonic() - start;
    stop = true;
    wire.join();
    a.join();
    b.join();
    char what[140];
    std::snprintf(what, sizeof what, "%d events of %zu bytes both ways, %.0f%% loss, real sockets: all there, in order, in %.2f s", total, bytes, loss_pct, took);
    check(met && in_order(at_guest, "h", total) && in_order(at_host, "g", total), what);
}

void test_sockets(int port) {
    std::puts("real sockets:");
    sure_over_sockets(port, 5, 500, 200);
    sure_over_sockets(port + 2, 30, 500, 200);
    sure_over_sockets(port + 4, 30, 500, relay::MAX_TEXT);

    // A stranger writing to a guest's port is stopped by the socket layer's address check.
    const auto quiet = [](const std::string&) {};
    relay::Mailbox box;
    relay::Relay guest("client", L".", std::make_unique<relay::UdpLink>("client", "127.0.0.1", port + 6, false, true), nullptr, {}, "test", quiet, box);
    const std::string self = guest.describe_self();
    const int guest_port = std::atoi(self.c_str() + 4);
    SOCKET stranger = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_in to{};
    to.sin_family = AF_INET;
    to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    to.sin_port = htons(static_cast<u_short>(guest_port));
    RawHeader h;
    h.flags = relay::FLAG_FROM_HOST;
    const std::string packet = raw_packet(h);
    sendto(stranger, packet.data(), static_cast<int>(packet.size()), 0, reinterpret_cast<sockaddr*>(&to), sizeof to);
    closesocket(stranger);
    Sleep(50);
    guest.tick(monotonic());
    const std::string status = guest.status(monotonic());
    check(status.find(" filtered=1 ") != std::string::npos && status.find(" received=0 ") != std::string::npos, "a stranger's packet to a guest's real socket is filtered");
}

int run_tests(int argc, wchar_t** argv) {
    test_timeline();
    test_timeline_odd();
    test_timeline_speed();
    test_latency();
    test_lanes();
    test_packets();
    test_partners();
    test_secret();
    test_hello();
    test_wire();
    test_sessions();
    test_restarts();
    test_silence();
    test_hostile();
    test_party();
    if (opt_number(argc, argv, L"--sockets", 1) != 0) {
        try {
            test_sockets(static_cast<int>(opt_number(argc, argv, L"--port", 47960)));
        } catch (const std::exception& e) {
            check(false, std::string("real sockets: ") + e.what());
        }
    }
    std::printf("%s\n", checks_failed ? "FAILED" : "all passed");
    return checks_failed ? 1 : 0;
}

// Runs one end of a real connection the way the game does: one frame's work 60 times a second.
int run_bot(int argc, wchar_t** argv) {
    relay::Options o;
    o.role = relay::narrow(argv[2]);
    o.peer = relay::narrow(opt_text(argc, argv, L"--peer", L"127.0.0.1"));
    o.port = static_cast<int>(opt_number(argc, argv, L"--port", 47810));
    o.dir = opt_text(argc, argv, L"--dir", L".");
    o.ini = opt_text(argc, argv, L"--ini", L"");
    o.version = "bot";
    o.this_pc_only = true;
    const double seconds = opt_number(argc, argv, L"--seconds", 20);
    const double fps = opt_number(argc, argv, L"--fps", 60);
    const int enemies = static_cast<int>(opt_number(argc, argv, L"--enemies", 0));
    const double hitch_every = opt_number(argc, argv, L"--hitch-every", 0);
    const double hitch_ms = opt_number(argc, argv, L"--hitch-ms", 300);
    const double center_x = opt_number(argc, argv, L"--cx", 0), center_y = opt_number(argc, argv, L"--cy", 0);
    const double center_z = opt_number(argc, argv, L"--cz", 0);
    const double event_every = opt_number(argc, argv, L"--event-every", 0.1);
    const double events_for = opt_number(argc, argv, L"--events-for", seconds);
    const size_t event_bytes = static_cast<size_t>(opt_number(argc, argv, L"--event-bytes", 0));
    int burst = static_cast<int>(opt_number(argc, argv, L"--burst", 0));
    o.seconds = seconds + 2;
    CreateDirectoryW(o.dir.c_str(), nullptr);
    std::thread net([&] { relay::run(o, [](const std::string& line) { if (line.rfind("role=", 0) != 0) std::puts(line.c_str()); }); });
    timeBeginPeriod(1);

    Stats ghost_late, quick_late, sure_late, step_error, enemy_late, player_late, passed_late;
    long long quick_got = 0, sure_got = 0, quick_sent = 0, sure_sent = 0;
    long long sure_expected = 0, sure_wrong = 0, restarts = 0;
    std::map<int, long long> expected_from, got_from;      // a party: by slot, what came from each other player
    long long passed_wrong = 0;
    const auto post_sure = [&](double now) {
        char head[64];
        std::snprintf(head, sizeof head, "E %lld %.6f ", ++sure_sent, now);
        std::string text = head;
        text.resize(std::max(text.size(), event_bytes), 'x');
        relay::mail.post_sure(std::move(text));
    };
    double last_angle = 0, last_frame = 0;
    bool have_last = false;
    const double begin = monotonic();
    double next_frame = begin, next_event = begin + 1, next_enemy = begin, next_hitch = begin + hitch_every;
    while (true) {
        const double now = monotonic();
        if (now - begin >= seconds) break;
        relay::Sample me;
        me.ms = static_cast<uint32_t>(relay::clock_ms());
        const double angle = now * TURN_RATE;
        me.x = static_cast<float>(center_x + RADIUS_CM * std::cos(angle));
        me.y = static_cast<float>(center_y + RADIUS_CM * std::sin(angle));
        me.z = static_cast<float>(center_z);
        me.vx = static_cast<float>(-SPEED_CM_S * std::sin(angle));
        me.vy = static_cast<float>(SPEED_CM_S * std::cos(angle));
        me.yaw = static_cast<float>(angle * 180 / PI);
        me.hp = 100;
        me.max_hp = 100;
        me.flags = relay::FLAG_GROUNDED;
        relay::mail.post_sample(me);

        if (now >= next_event && now - begin < events_for) {
            next_event = now + event_every;
            char text[64];
            std::snprintf(text, sizeof text, "Q %.6f", now);
            relay::mail.post_quick(text);
            quick_sent++;
            post_sure(now);
            for (; burst > 0; burst--) post_sure(now);
        }
        if (enemies && now >= next_enemy) {
            next_enemy = now + 0.05;
            for (int i = 0; i < enemies; i++) {
                char text[96];
                std::snprintf(text, sizeof text, "%d %.6f 1234 5678 90 180 800 90", i, now);
                relay::mail.post_enemy(text);
            }
        }

        relay::Sample p;
        double silence = 0, delay = 0;
        if (relay::mail.partner(relay::clock_ms(), p, silence, delay)) {
            // Which moment of the partner's path is being shown, from the position alone.
            double angle_seen = std::atan2(p.y - center_y, p.x - center_x);
            double turns = std::round((now * TURN_RATE - angle_seen) / (2 * PI));
            angle_seen += turns * 2 * PI;
            ghost_late.add((now - angle_seen / TURN_RATE) * 1000);
            if (have_last) {
                const double moved = (angle_seen - last_angle) * RADIUS_CM;
                step_error.add(std::fabs(moved - SPEED_CM_S * (now - last_frame)));
            }
            have_last = true;
            last_angle = angle_seen;
            last_frame = now;
        }
        for (int slot = relay::FIRST_GUEST_SLOT; slot <= relay::MAX_SLOT; slot++) {
            if (!relay::mail.player(slot, relay::clock_ms(), p, silence, delay)) continue;
            double angle_seen = std::atan2(p.y - center_y, p.x - center_x);
            angle_seen += std::round((now * TURN_RATE - angle_seen) / (2 * PI)) * 2 * PI;
            if (silence < 500) player_late.add((now - angle_seen / TURN_RATE) * 1000);
        }
        std::string events = relay::mail.take_events(relay::clock_ms());
        for (size_t at = 0; at < events.size();) {
            size_t end = events.find('\n', at);
            std::string line = events.substr(at, end - at);
            at = end + 1;
            if (line.size() > 3 && line[0] == '@') {
                const int from = line[1] - '0';
                line.erase(0, 3);
                if (line.size() > 2 && line[0] == 'E') {
                    char* rest = nullptr;
                    const long long number = std::strtoll(line.c_str() + 2, &rest, 10);
                    passed_late.add((monotonic() - std::atof(rest)) * 1000);
                    got_from[from]++;
                    if (expected_from[from] && number != expected_from[from]) passed_wrong++;
                    expected_from[from] = number + 1;
                }
            } else if (line.size() > 2 && line[0] == 'Q') {
                quick_late.add((monotonic() - std::atof(line.c_str() + 2)) * 1000);
                quick_got++;
            } else if (line.size() > 2 && line[0] == 'E') {
                char* rest = nullptr;
                const long long number = std::strtoll(line.c_str() + 2, &rest, 10);
                sure_late.add((monotonic() - std::atof(rest)) * 1000);
                sure_got++;
                if (sure_expected && number != sure_expected) sure_wrong++;
                sure_expected = number + 1;
            } else if (line == "S") {
                restarts++;
                sure_expected = 0;      // the partner's numbering starts over, or we joined after it began
            }
        }
        std::string list = relay::mail.take_enemies();
        for (size_t at = 0; at < list.size();) {
            size_t end = list.find('\n', at);
            std::string line = list.substr(at, end - at);
            at = end + 1;
            size_t space = line.find(' ');
            if (space != std::string::npos) enemy_late.add((monotonic() - std::atof(line.c_str() + space + 1)) * 1000);
        }
        if (hitch_every > 0 && now >= next_hitch) {
            next_hitch = now + hitch_every;
            Sleep(static_cast<DWORD>(hitch_ms));   // the game thread standing still (a load, a shader)
        }
        next_frame += 1.0 / fps;
        const double wait = next_frame - monotonic();
        if (wait > 0) Sleep(static_cast<DWORD>(wait * 1000));
        else next_frame = monotonic();
    }
    net.join();
    timeEndPeriod(1);
    std::printf("--- %s after %.0f s\n", o.role.c_str(), seconds);
    std::printf("%s\n", relay::mail.status().c_str());
    ghost_late.print("ghost behind real (ms)");
    step_error.print("frame step error (cm)");
    quick_late.print("quick event (ms)");
    sure_late.print("sure event (ms)");
    if (enemies) enemy_late.print("enemy line (ms)");
    std::printf("quick arrived %lld of the partner's sent; sure %lld; this side sent %lld quick, %lld sure\n", quick_got, sure_got, quick_sent, sure_sent);
    std::printf("sure_lane got=%lld wrong_order=%lld restarts=%lld sent=%lld\n", sure_got, sure_wrong, restarts, sure_sent);
    if (!player_late.v.empty()) {
        player_late.print("other players (ms)");
        passed_late.print("others' sure events (ms)");
        std::printf("passed_on");
        for (const auto& [slot, n] : got_from) std::printf(" from%d=%lld", slot, n);
        std::printf(" wrong_order=%lld\n", passed_wrong);
    }
    return 0;
}

// Sits between a client and a host on this PC and treats every packet the way a bad connection would.
int netem(const Netem& o, const std::atomic<bool>* stop) {
    const double delay = o.delay, jitter = o.jitter, loss = o.loss / 100, duplicate = o.duplicate / 100, seconds = o.seconds;
    const double stall_every = o.stall_every, stall_ms = o.stall_ms;
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET front = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP), back = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(static_cast<u_short>(o.listen));
    if (bind(front, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0) {
        std::puts("netem: can't use that port");
        return 1;
    }
    u_long nonblocking = 1;
    ioctlsocket(front, FIONBIO, &nonblocking);
    ioctlsocket(back, FIONBIO, &nonblocking);
    sockaddr_in target = a, client{};
    target.sin_port = htons(static_cast<u_short>(o.target));
    bool have_client = false;
    struct Held {
        double at;
        long long order;
        bool to_target;
        std::string data;
        bool operator<(const Held& o) const { return at != o.at ? at > o.at : order > o.order; }
    };
    std::priority_queue<Held> held;
    std::mt19937 rng(7);
    std::uniform_real_distribution<double> unit(0, 1);
    timeBeginPeriod(1);
    const double start = monotonic();
    double stall_until = 0, next_stall = start + stall_every;
    long long passed = 0, dropped = 0, order = 0;
    std::vector<char> buf(65536);
    while (monotonic() - start < seconds && !(stop && *stop)) {
        const double now = monotonic();
        if (stall_every > 0 && now >= next_stall) {
            stall_until = now + stall_ms / 1000;
            next_stall = now + stall_every;
        }
        const auto take = [&](SOCKET from, bool to_target) {
            while (true) {
                sockaddr_in src{};
                int len = sizeof src;
                int n = recvfrom(from, buf.data(), static_cast<int>(buf.size()), 0, reinterpret_cast<sockaddr*>(&src), &len);
                if (n <= 0) {
                    if (n < 0 && WSAGetLastError() == WSAECONNRESET) continue;
                    return;
                }
                if (to_target) {
                    client = src;
                    have_client = true;
                }
                if (unit(rng) < loss) {
                    dropped++;
                    continue;
                }
                double at = now + (delay + unit(rng) * jitter) / 1000;
                at = std::max(at, stall_until);
                held.push({at, order++, to_target, std::string(buf.data(), n)});
                if (unit(rng) < duplicate) held.push({at + unit(rng) * 0.02, order++, to_target, std::string(buf.data(), n)});
            }
        };
        take(front, true);
        take(back, false);
        while (!held.empty() && held.top().at <= now) {
            const Held& h = held.top();
            if (h.to_target) sendto(back, h.data.data(), static_cast<int>(h.data.size()), 0, reinterpret_cast<sockaddr*>(&target), sizeof target);
            else if (have_client) sendto(front, h.data.data(), static_cast<int>(h.data.size()), 0, reinterpret_cast<sockaddr*>(&client), sizeof client);
            passed++;
            held.pop();
        }
        Sleep(0);
    }
    timeEndPeriod(1);
    closesocket(front);
    closesocket(back);
    if (!stop) std::printf("netem: passed %lld, dropped %lld\n", passed, dropped);
    return 0;
}

// "30,80,150" -> 30, 80, 150.
std::vector<double> opt_list(int argc, wchar_t** argv, const wchar_t* name, std::vector<double> fallback) {
    for (int i = 1; i + 1 < argc; i++) {
        if (std::wcscmp(argv[i], name) != 0) continue;
        std::vector<double> out;
        for (const wchar_t* at = argv[i + 1]; *at;) {
            wchar_t* end = nullptr;
            out.push_back(std::wcstod(at, &end));
            if (end == at) break;
            at = *end == L',' ? end + 1 : end;
        }
        return out;
    }
    return fallback;
}

// Every connection of the grid, one line each for the playback's target and for the ghost walking after it, then the
// means. A recording replaces the made-up sender (and its frame rate) with the real game's frames.
int run_latency(int argc, wchar_t** argv) {
    const std::string kind = relay::narrow(opt_text(argc, argv, L"--path", L"mix"));
    const std::string file = relay::narrow(opt_text(argc, argv, L"--recording", L""));
    const double seconds = opt_number(argc, argv, L"--seconds", 60);
    const auto rtts = opt_list(argc, argv, L"--rtt", {30, 80, 150});
    const auto jitters = opt_list(argc, argv, L"--jitter", {0, 10, 30});
    const auto losses = opt_list(argc, argv, L"--loss", {0, 2, 5});
    const auto fpss = file.empty() ? opt_list(argc, argv, L"--fps", {30, 60, 120}) : std::vector<double>{0};
    const double recv_fps = opt_number(argc, argv, L"--recv-fps", 60);
    const bool brief = opt_number(argc, argv, L"--brief", 0) != 0;
    // coop.lua's rule: every frame, at most 125 a second. --send-rate 0 is the rule before it, 1/62 s after the last send.
    const double send_rate = opt_number(argc, argv, L"--send-rate", 125);
    const lab::Sending sending = send_rate > 0 ? lab::Sending{0, 0, send_rate} : lab::Sending{};
    lab::Recorded rec;
    lab::Path path;
    if (!file.empty()) {
        rec = lab::load_recording(file);
        path = lab::path_of(rec);
        if (path.x.empty()) {
            std::puts("latency: no P rows in that recording");
            return 1;
        }
    } else {
        path = lab::make_path(kind, seconds, 11);
    }
    static const char* const NAMES[] = {"behind50", "behind95", "behind99", "now95", "path99", "step99", "stepmax", "speed95",
                                        "stop50", "stopmax", "backmax"};
    constexpr size_t N = sizeof NAMES / sizeof NAMES[0];
    const auto numbers = [](lab::Measures& m, double* v) {
        const double got[N] = {m.behind(0.5), m.behind(0.95), m.behind(0.99), m.now(0.95), m.path(0.99), m.step(0.99), m.step(1.0),
                               m.speed(0.95), m.overshoot(0.5), m.overshoot(1.0), m.back(1.0)};
        std::copy(got, got + N, v);
    };
    double sums[2][N] = {};
    int runs = 0;
    std::printf("%s, %.0f s, %zu stops; receiver at %.0f FPS. ms for behind, cm for the rest (speed cm/s)\n",
                file.empty() ? kind.c_str() : file.c_str(), path.length_ms() / 1000, path.stops.size(), recv_fps);
    std::printf("%-26s", "rtt jitter loss fps");
    for (const char* name : NAMES) std::printf("%9s", name);
    std::printf("\n");
    uint32_t seed = 1;
    for (double rtt : rtts)
        for (double jitter : jitters)
            for (double loss : losses)
                for (double fps : fpss) {
                    lab::TimelinePlayback play;
                    const lab::Link link{rtt, jitter, loss};
                    lab::Run r = lab::run(path, file.empty() ? nullptr : &rec, link, fps ? fps : 60, recv_fps, play, seed++, sending);
                    for (int stage = 0; stage < 2; stage++) {
                        double v[N];
                        numbers(stage ? r.ghost : r.target, v);
                        for (size_t i = 0; i < N; i++) sums[stage][i] += v[i];
                        if (brief) continue;
                        char label[64];
                        std::snprintf(label, sizeof label, "%3.0f %3.0f %2.0f%% %3.0f %s", rtt, jitter, loss, fps, stage ? "ghost " : "target");
                        std::printf("%-26s", label);
                        for (double x : v) std::printf("%9.1f", x);
                        std::printf("\n");
                    }
                    runs++;
                }
    for (int stage = 0; stage < 2; stage++) {
        std::printf("%-26s", stage ? "mean ghost" : "mean target");
        for (double s : sums[stage]) std::printf("%9.1f", s / runs);
        std::printf("\n");
    }
    return 0;
}

int run_netem(int argc, wchar_t** argv) {
    Netem o;
    o.listen = _wtoi(argv[2]);
    o.target = _wtoi(argv[3]);
    o.delay = opt_number(argc, argv, L"--delay", 10);
    o.jitter = opt_number(argc, argv, L"--jitter", 0);
    o.loss = opt_number(argc, argv, L"--loss", 0);
    o.duplicate = opt_number(argc, argv, L"--duplicate", 0);
    o.seconds = opt_number(argc, argv, L"--seconds", 60);
    o.stall_every = opt_number(argc, argv, L"--stall-every", 0);
    o.stall_ms = opt_number(argc, argv, L"--stall-ms", 200);
    return netem(o, nullptr);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    std::setvbuf(stdout, nullptr, _IOLBF, 4096);
    const std::wstring mode = argc > 1 ? argv[1] : L"";
    if (mode == L"test") return run_tests(argc, argv);
    if (mode == L"bot" && argc > 2) return run_bot(argc, argv);
    if (mode == L"netem" && argc > 3) return run_netem(argc, argv);
    if (mode == L"latency") return run_latency(argc, argv);
    std::fputs("usage: relay_cli test [--sockets 0] [--port n] | bot host|client [--port n] [--peer ip] [--seconds s] [--fps n] [--enemies n]"
               " [--hitch-every s --hitch-ms ms] [--cx x --cy y --cz z] [--dir folder] [--ini file]"
               " [--event-every s] [--event-bytes n] [--events-for s] [--burst n]"
               " | netem <listen port> <target port>"
               " [--delay ms] [--jitter ms] [--loss %] [--duplicate %] [--stall-every s --stall-ms ms] [--seconds s]"
               " | latency [--path mix|circle|stops|zigzag | --recording pair.txt] [--seconds s] [--rtt 30,80,150]"
               " [--jitter 0,10,30] [--loss 0,2,5] [--fps 30,60,120] [--recv-fps n] [--send-rate 125|0] [--brief 1]\n", stderr);
    return 2;
}

// The console tool has no game around it, so no Steam.
std::unique_ptr<relay::Link> relay::make_steam_link(const std::string&, const std::string&) {
    throw std::runtime_error("relay_cli has no Steam: the Steam link only works inside the game");
}
