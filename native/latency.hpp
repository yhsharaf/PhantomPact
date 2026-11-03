// How far behind the partner's figure shows, and how smoothly, end to end in simulated time (relay_cli latency): the
// sender's game frames and samples, a bad connection, the playback, the receiver's frames, and the ghost walking the way
// coop.lua steers it. For relay_cli only; main.dll never includes it.
//
// Everything is measured against where the sender really was, every millisecond. The sender's motion is either made up
// from what recordings of the real game show (starts take a quarter of a second, a stop takes one frame, turns run at about
// 25 degrees a frame), or a pair.lua recording played back as it was.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <queue>
#include <random>
#include <string>
#include <vector>

#include "timeline.hpp"

namespace lab {

constexpr double PI = 3.14159265358979323846;

// Where the sender really was, one entry a millisecond from 0.
struct Path {
    std::vector<double> x, y, vx, vy;
    std::vector<double> stops;          // ms: a run that ends in a sudden stop, followed by standing still
    double length_ms() const { return x.empty() ? 0 : static_cast<double>(x.size() - 1); }

    void at(double t, double& px, double& py) const {
        t = std::clamp(t, 0.0, length_ms());
        const size_t i = std::min(static_cast<size_t>(t), x.size() - 2);
        const double f = t - static_cast<double>(i);
        px = x[i] + (x[i + 1] - x[i]) * f;
        py = y[i] + (y[i + 1] - y[i]) * f;
    }

    void velocity(double t, double& pvx, double& pvy) const {
        const size_t i = static_cast<size_t>(std::clamp(t, 0.0, length_ms()));
        pvx = vx[i];
        pvy = vy[i];
    }

    double speed(double t) const {
        double a, b;
        velocity(t, a, b);
        return std::hypot(a, b);
    }
};

// A stretch of the made-up motion: head this way at this speed for this long.
struct Leg {
    double ms, heading, speed;
    double accel, decel;     // cm/s²: how fast speed is gained and lost on the way to this leg's
    double curve = 0;        // degrees a second the heading drifts while it runs
};

// The velocity follows the legs as a character would: speed changes at the leg's rates, the heading turns at most
// TURN_DEG_S, and from a standstill it sets off in the new direction at once.
inline Path walk_legs(const std::vector<Leg>& legs) {
    constexpr double TURN_DEG_S = 1500;
    Path p;
    double x = 0, y = 0, speed = 0, heading = 0;
    for (const Leg& leg : legs) {
        const size_t n = static_cast<size_t>(leg.ms);
        double want = leg.heading;
        const bool stopping = leg.speed < 1 && leg.decel > 20000;
        if (stopping && speed > 300) p.stops.push_back(static_cast<double>(p.x.size()));
        for (size_t i = 0; i < n; i++) {
            want += leg.curve / 1000;
            if (speed < 5) heading = want;
            const double turn = std::fmod(want - heading + 540.0, 360.0) - 180.0;
            heading += std::clamp(turn, -TURN_DEG_S / 1000, TURN_DEG_S / 1000);
            if (leg.speed > speed) speed = std::min(leg.speed, speed + leg.accel / 1000);
            else speed = std::max(leg.speed, speed - leg.decel / 1000);
            const double vx = speed * std::cos(heading * PI / 180), vy = speed * std::sin(heading * PI / 180);
            p.x.push_back(x);
            p.y.push_back(y);
            p.vx.push_back(vx);
            p.vy.push_back(vy);
            x += vx / 1000;
            y += vy / 1000;
        }
    }
    return p;
}

constexpr double RUN = 600, START = 1500, HARD = 40000, QUICK = 6000;

// "circle": steady running on a circle, the relay_cli bot's path. "stops": runs that end in a sudden stop, then a stand.
// "zigzag": combat footwork, a new direction every third of a second. "mix": all of these, turns and dodges, as in play.
inline Path make_path(const std::string& kind, double seconds, uint32_t seed) {
    std::mt19937 rng(seed);
    const auto pick = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(rng); };
    std::vector<Leg> legs;
    double total = 0, heading = 0;
    const auto add = [&](Leg leg) {
        legs.push_back(leg);
        total += leg.ms;
    };
    const auto stand = [&](double ms) { add({ms, heading, 0, START, HARD}); };
    if (kind == "circle") {
        add({seconds * 1000, 0, RUN, 1e9, HARD, RUN / 1000 * 180 / PI});
        Path p = walk_legs(legs);
        p.stops.clear();
        return p;
    }
    stand(500);
    while (total < seconds * 1000) {
        const double roll = pick(0, 1);
        if (kind == "stops" || (kind == "mix" && roll < 0.3)) {
            heading = pick(-180, 180);
            add({pick(1200, 2500), heading, pick(500, 650), START, QUICK, pick(-40, 40)});
            stand(pick(800, 1200));
        } else if (kind == "zigzag" || (kind == "mix" && roll < 0.55)) {
            const double base = pick(-180, 180);
            for (int i = 0; i < 6; i++) add({pick(250, 400), base + (i % 2 ? 80 : -80), pick(350, 450), QUICK, QUICK});
            stand(pick(800, 1200));
        } else if (kind == "mix" && roll < 0.75) {
            heading = pick(-180, 180);
            add({pick(800, 1500), heading, RUN, START, QUICK});
            heading += pick(0, 1) < 0.5 ? pick(60, 120) : 180;
            add({pick(800, 1500), heading, RUN, QUICK, QUICK});
            stand(pick(800, 1200));
        } else if (kind == "mix" && roll < 0.9) {
            heading = pick(-180, 180);
            add({pick(500, 900), heading, RUN, START, QUICK});
            add({pick(200, 300), heading + pick(-120, 120), 1400, 60000, 60000});
            stand(pick(800, 1200));
        } else {
            heading = pick(-180, 180);
            add({pick(1000, 2000), heading, pick(120, 180), START, QUICK, pick(-30, 30)});
            stand(pick(600, 900));
        }
    }
    return walk_legs(legs);
}

// A pair.lua recording ("P <seconds> <x> <y> <z> <yaw>" rows): the frames the game read, with their own stamps.
// A teleport (as the Timeline tells one) is taken out: the path goes on from where it was.
struct Recorded {
    std::vector<double> ms, x, y;
};

inline Recorded load_recording(const std::string& file) {
    Recorded r;
    std::ifstream in(file);
    std::string line;
    double sx = 0, sy = 0, last_x = 0, last_y = 0;
    while (std::getline(in, line)) {
        if (line.size() < 3 || line[0] != 'P' || line[1] != ' ') continue;
        char* at = line.data() + 2;
        double v[3];
        bool ok = true;
        for (double& n : v) {
            char* end = nullptr;
            n = std::strtod(at, &end);
            ok = ok && end != at;
            at = end;
        }
        if (!ok) continue;
        const double t = v[0], x = v[1], y = v[2];
        if (!r.ms.empty() && t * 1000 <= r.ms.back()) continue;
        const double hop = std::hypot(x - last_x, y - last_y);
        if (!r.ms.empty() && hop > relay::Timeline::JUMP_CM && hop / (t * 1000 - r.ms.back()) * 1000 > relay::Timeline::JUMP_SPEED_CM_S) {
            sx += last_x - x;
            sy += last_y - y;
        }
        last_x = x;
        last_y = y;
        r.ms.push_back(t * 1000);
        r.x.push_back(x + sx);
        r.y.push_back(y + sy);
    }
    if (r.ms.empty()) return r;
    const double t0 = r.ms.front();
    for (double& t : r.ms) t -= t0;
    return r;
}

// The recording as a path: its rows joined by straight lines.
inline Path path_of(const Recorded& r) {
    Path p;
    if (r.ms.size() < 2) return p;
    size_t row = 0;
    for (double t = 0; t <= r.ms.back(); t += 1) {
        while (row + 2 < r.ms.size() && r.ms[row + 1] <= t) row++;
        const double span = r.ms[row + 1] - r.ms[row], f = std::clamp((t - r.ms[row]) / span, 0.0, 1.0);
        p.x.push_back(r.x[row] + (r.x[row + 1] - r.x[row]) * f);
        p.y.push_back(r.y[row] + (r.y[row + 1] - r.y[row]) * f);
        p.vx.push_back((r.x[row + 1] - r.x[row]) / span * 1000);
        p.vy.push_back((r.y[row + 1] - r.y[row]) / span * 1000);
    }
    return p;
}

// How a game's frames come: mostly even, a few late, and a hitch every 8 s or so whatever the frame rate.
struct Frames {
    double fps = 60;
    std::mt19937 rng;
    explicit Frames(double f, uint32_t seed) : fps(f), rng(seed) {}
    double next() {
        std::uniform_real_distribution<double> unit(0, 1);
        double dt = 1000 / fps * (1 + (unit(rng) - 0.5) * 0.12);
        if (unit(rng) < 0.03) dt += 2 + unit(rng) * 6;
        if (unit(rng) < dt / 8000) dt += 40 + unit(rng) * 80;
        return dt;
    }
    // The mod's tick runs somewhere in the frame, after the game moved the player: the stamp is that much late.
    double tick_offset() { return std::uniform_real_distribution<double>(0, 4)(rng); }
};

struct Link {
    double rtt = 80, jitter = 10, loss = 0;     // ms, ms, percent
    double stall_every = 0, stall_ms = 0;       // s, ms: as netem's: what's sent during one waits for its end
};

// Which frames the mod sends (coop.lua's sendPlayer): one at least every_ms after the last, less slack_ms; or with
// rate set, every frame as long as the sends stay under rate a second (a budget that fills with time, holding up to 1.5).
// With timer_hz set, every frame is posted and the relay thread sends the newest on a timer of its own instead.
struct Sending {
    double every_ms = 1000.0 / 62, slack_ms = 0, rate = 0, timer_hz = 0;
};

// The ghost's movement as UE's CharacterMovementComponent walks it (CalcVelocity), driven the way coop.lua's
// steerGhost drives it. MaxAcceleration is coop.lua's; friction is UE's default; braking is what the real character
// shows in the recordings (a stop in one frame). The mod's tick comes after the game's movement in a frame, as the
// recordings show (the ghost runs about as far behind as its target): what it steers now moves the ghost next frame.
struct Ghost {
    static constexpr double ACCEL = 12000, FRICTION = 8, BRAKING_FRICTION = 16, BRAKING = 30000;
    static constexpr double SNAP_CM = 600, PULL = 6, STILL = 25, MAX_SPEED = 2200;
    double x = 0, y = 0, vx = 0, vy = 0, max_walk = 0;
    bool placed = false;

    // The game's movement this frame, on the input from the last.
    void move(double dt_ms) {
        const double dt = std::max(dt_ms, 0.5) / 1000;
        calc_velocity(ax_, ay_, dt);
        x += vx * dt;
        y += vy * dt;
    }

    // steerGhost, walking ghost.
    void steer(const relay::Sample& t) {
        if (!placed) {
            x = t.x;
            y = t.y;
            placed = true;
        }
        const double dx = t.x - x, dy = t.y - y;
        ax_ = ay_ = 0;
        if (std::hypot(dx, dy) > SNAP_CM) {
            x = t.x;
            y = t.y;
            return;
        }
        const double cx = t.vx + dx * PULL, cy = t.vy + dy * PULL, speed = std::hypot(cx, cy);
        if (speed > STILL) {
            max_walk = std::min(MAX_SPEED, speed);
            ax_ = cx / speed * ACCEL;
            ay_ = cy / speed * ACCEL;
        }
    }

private:
    double ax_ = 0, ay_ = 0;

    void calc_velocity(double ax, double ay, double dt) {
        const bool no_input = ax == 0 && ay == 0;
        const double max_speed = max_walk;
        const bool over = std::hypot(vx, vy) > max_speed * 1.01;
        if (no_input || over) {
            const double ox = vx, oy = vy;
            brake(dt);
            if (over && std::hypot(vx, vy) < max_speed && ax * ox + ay * oy > 0) {
                const double s = std::hypot(ox, oy);
                vx = ox / s * max_speed;
                vy = oy / s * max_speed;
            }
        } else {
            const double a = std::hypot(ax, ay), s = std::hypot(vx, vy), k = std::min(dt * FRICTION, 1.0);
            vx -= (vx - ax / a * s) * k;
            vy -= (vy - ay / a * s) * k;
        }
        if (!no_input) {
            const double limit = std::hypot(vx, vy) > max_speed * 1.01 ? std::hypot(vx, vy) : max_speed;
            vx += ax * dt;
            vy += ay * dt;
            const double s = std::hypot(vx, vy);
            if (s > limit) {
                vx *= limit / s;
                vy *= limit / s;
            }
        }
    }

    void brake(double dt) {
        const double s0 = std::hypot(vx, vy);
        if (s0 == 0) return;
        const double ox = vx, oy = vy, rx = -BRAKING * vx / s0, ry = -BRAKING * vy / s0;
        const double max_step = 1.0 / 33;
        double left = dt;
        while (left >= 1e-6) {
            const double step = left > max_step ? std::min(max_step, left * 0.5) : left;
            left -= step;
            vx += (-BRAKING_FRICTION * vx + rx) * step;
            vy += (-BRAKING_FRICTION * vy + ry) * step;
            if (vx * ox + vy * oy <= 0) {
                vx = vy = 0;
                return;
            }
        }
        if (std::hypot(vx, vy) <= 10) vx = vy = 0;
    }
};

// What plays the partner back: relay::Timeline, or a variant of it being tried.
class Playback {
public:
    virtual ~Playback() = default;
    virtual void push(const relay::Sample& s, double arrived_ms) = 0;
    virtual bool at(double now_ms, relay::Sample& out) = 0;
    virtual void rtt(double) {}    // the round trip, as the relay measures it
};

class TimelinePlayback : public Playback {
public:
    void push(const relay::Sample& s, double arrived_ms) override { line_.push(s, arrived_ms); }
    bool at(double now_ms, relay::Sample& out) override { return line_.at(now_ms, out); }

private:
    relay::Timeline line_;
};

struct Pct {
    std::vector<double> v;
    void add(double x) { v.push_back(x); }
    double operator()(double p) {
        if (v.empty()) return 0;
        std::sort(v.begin(), v.end());
        return v[std::min(v.size() - 1, static_cast<size_t>(v.size() * p))];
    }
};

// One stage's numbers: the playback's target, or the ghost walking after it.
struct Measures {
    Pct behind;      // ms: which moment of the true path is shown, how long ago
    Pct now;         // cm: from where the sender is at this moment
    Pct path;        // cm: from the nearest point of the true path, near that moment
    Pct step;        // cm: a frame's move against the true path's over the same frame, at the usual delay
    Pct speed;       // cm/s: speed shown against the true speed, at the usual delay
    Pct overshoot;   // cm: past the point where a sudden stop ended
    Pct back;        // cm: of that, how far it then came back
};

struct Shown {
    double now, x, y;
};

// Fills m from what was shown each frame. Frames where the sender barely moves have no "moment" to find, and count
// for nothing but the errors. A stop inside one of the sender's hitches isn't one a game can make (the stick is read
// between frames, and a long frame goes on at the speed it started with), so it doesn't count as a stop.
inline void measure(const Path& p, const std::vector<Shown>& shown, Measures& m, double settle_ms,
                    const std::vector<std::pair<double, double>>& hitches = {}) {
    Pct all;
    for (const Shown& s : shown) {
        if (s.now < settle_ms || s.now > p.length_ms() - 300) continue;
        double tx, ty;
        p.at(s.now, tx, ty);
        m.now.add(std::hypot(s.x - tx, s.y - ty));
        // The nearest point on the true path from 400 ms back to 150 ms ahead, coarse then fine.
        double best = 1e18, best_t = s.now;
        for (double t = s.now - 400; t <= s.now + 150; t += 4) {
            p.at(t, tx, ty);
            const double d = std::hypot(s.x - tx, s.y - ty);
            if (d < best) best = d, best_t = t;
        }
        for (double t = best_t - 4; t <= best_t + 4; t += 0.25) {
            p.at(t, tx, ty);
            const double d = std::hypot(s.x - tx, s.y - ty);
            if (d < best) best = d, best_t = t;
        }
        m.path.add(best);
        bool moving = true;
        for (double t = s.now - 400; t <= s.now && moving; t += 10) moving = p.speed(t) > 150;
        if (moving) {
            m.behind.add(s.now - best_t);
            all.add(s.now - best_t);
        }
    }
    const double usual = all(0.5);
    for (size_t i = 1; i < shown.size(); i++) {
        const Shown &a = shown[i - 1], &b = shown[i];
        if (a.now < settle_ms || b.now > p.length_ms() - 300) continue;
        double ax, ay, bx, by;
        p.at(a.now - usual, ax, ay);
        p.at(b.now - usual, bx, by);
        const double ex = (b.x - a.x) - (bx - ax), ey = (b.y - a.y) - (by - ay);
        m.step.add(std::hypot(ex, ey));
        const double dt = (b.now - a.now) / 1000;
        if (dt > 0) m.speed.add(std::fabs(std::hypot(b.x - a.x, b.y - a.y) / dt - std::hypot(bx - ax, by - ay) / dt));
    }
    for (double stop : p.stops) {
        if (stop < settle_ms || stop + 1500 > p.length_ms()) continue;
        if (std::any_of(hitches.begin(), hitches.end(), [&](const auto& h) { return stop + 30 > h.first && stop - 30 < h.second; }))
            continue;
        double ux, uy, sx, sy;
        p.velocity(stop - 5, ux, uy);
        const double u = std::hypot(ux, uy);
        if (u < 1) continue;
        ux /= u;
        uy /= u;
        p.at(stop + 200, sx, sy);
        double most = -1e18, last = 0;
        for (const Shown& s : shown) {
            if (s.now < stop || s.now > stop + 750) continue;
            const double ahead = (s.x - sx) * ux + (s.y - sy) * uy;
            most = std::max(most, ahead);
            last = ahead;
        }
        if (most < -1e17) continue;
        m.overshoot.add(std::max(0.0, most));
        m.back.add(std::max(0.0, most - std::max(0.0, last)));
    }
}

struct Run {
    Measures target, ghost;
    std::vector<Shown> targets, ghosts;     // every frame, for a closer look
    double sent = 0, delivered = 0;
};

// One sender, one link, one receiver, in simulated time. The sender's clock and the receiver's differ by an
// arbitrary amount, as two PCs' do.
inline Run run(const Path& p, const Recorded* rec, const Link& link, double send_fps, double recv_fps, Playback& play,
               uint32_t seed, Sending sending = {}) {
    const double send_every_ms = sending.every_ms - sending.slack_ms;
    constexpr double CLOCK_GAP = 7777777.25, SETTLE = 3000;
    std::mt19937 rng(seed);
    std::uniform_real_distribution<double> unit(0, 1);
    struct Arrival {
        double at;
        long long order;
        relay::Sample s;
        bool operator<(const Arrival& o) const { return at != o.at ? at > o.at : order > o.order; }
    };
    std::priority_queue<Arrival> wire;
    long long order = 0;
    std::vector<std::pair<double, double>> hitches;     // the sender's frames longer than 35 ms
    Run r;

    // The sender's frames and what the mod sends from them, all up front: the network doesn't change them.
    Frames sender(send_fps, seed * 3 + 1);
    double next_send = 0, rtt_seen = -1;
    // A sample stamped at stamp, leaving at when (at once, but for a relay timer).
    const auto send_at = [&](double when, double stamp, double x, double y, double vx, double vy) {
        relay::Sample s;
        s.ms = static_cast<uint32_t>(stamp + 1000);
        s.x = static_cast<float>(x);
        s.y = static_cast<float>(y);
        s.vx = static_cast<float>(vx);
        s.vy = static_cast<float>(vy);
        s.flags = relay::FLAG_GROUNDED;
        r.sent++;
        if (unit(rng) * 100 < link.loss) return;
        double arrive = when + 0.2 + link.rtt / 2 + unit(rng) * link.jitter;
        if (link.stall_every > 0) {
            const double period = link.stall_every * 1000, into = std::fmod(when, period);
            if (into >= period - link.stall_ms) arrive = std::max(arrive, when - into + period + link.rtt / 2);
        }
        wire.push({arrive + CLOCK_GAP, order++, s});
        r.delivered++;
    };
    const auto send = [&](double stamp, double x, double y, double vx, double vy) { send_at(stamp, stamp, x, y, vx, vy); };
    if (rec) {
        // The game's own velocity isn't in a recording: the last frame's move stands for it.
        double budget = 1;
        for (size_t i = 0; i < rec->ms.size(); i++) {
            const double stamp = rec->ms[i];
            if (sending.rate > 0) {
                budget = std::min(1.5, budget + (i ? stamp - rec->ms[i - 1] : 0) * sending.rate / 1000);
                if (budget < 1) continue;
                budget -= 1;
            } else {
                if (stamp < next_send) continue;
                next_send = stamp + send_every_ms;
            }
            const double dt = i ? rec->ms[i] - rec->ms[i - 1] : 16.7;
            const double vx = i ? (rec->x[i] - rec->x[i - 1]) / dt * 1000 : 0, vy = i ? (rec->y[i] - rec->y[i - 1]) / dt * 1000 : 0;
            send(stamp, rec->x[i], rec->y[i], vx, vy);
        }
    } else {
        double budget = 1, last_stamp = 0, tick = 0;
        struct Posted {
            double stamp, x, y, vx, vy;
        };
        std::optional<Posted> posted;
        for (double frame = 0, dt = 0; frame < p.length_ms(); frame += dt) {
            dt = sender.next();
            if (dt > 35) hitches.emplace_back(frame, frame + dt);
            const double stamp = frame + sender.tick_offset();
            if (sending.timer_hz > 0) {
                // The timer's sends up to this frame go out with whatever was posted last; then this frame's is posted.
                for (; tick <= stamp; tick += 1000 / sending.timer_hz) {
                    if (!posted) continue;
                    send_at(tick, posted->stamp, posted->x, posted->y, posted->vx, posted->vy);
                    posted.reset();
                }
                double x, y, vx, vy;
                p.at(frame, x, y);
                p.velocity(frame, vx, vy);
                posted = Posted{stamp, x, y, vx, vy};
                continue;
            }
            if (sending.rate > 0) {
                budget = std::min(1.5, budget + (stamp - last_stamp) * sending.rate / 1000);
                last_stamp = stamp;
                if (budget < 1) continue;
                budget -= 1;
            } else {
                if (stamp < next_send) continue;
                next_send = stamp + send_every_ms;
            }
            double x, y, vx, vy;
            p.at(frame, x, y);
            p.velocity(frame, vx, vy);
            send(stamp, x, y, vx, vy);
        }
    }

    // The receiver: arrivals as they land, a frame of the game in between.
    Frames receiver(recv_fps, seed * 7 + 5);
    Ghost ghost;
    std::vector<Shown>& targets = r.targets;
    std::vector<Shown>& ghosts = r.ghosts;
    double last_frame = -1;
    for (double frame = 0; frame < p.length_ms(); frame += receiver.next()) {
        const double now = frame + receiver.tick_offset();
        while (!wire.empty() && wire.top().at - CLOCK_GAP <= now) {
            play.push(wire.top().s, wire.top().at);
            // The round trip the relay learns from the echo: both ways' delay, smoothed as relay.hpp does.
            const double sample = link.rtt + (unit(rng) + unit(rng)) * link.jitter;
            rtt_seen = rtt_seen < 0 ? sample : rtt_seen + (sample - rtt_seen) * 0.1;
            play.rtt(rtt_seen);
            wire.pop();
        }
        if (ghost.placed) {
            ghost.move(frame - last_frame);
            ghosts.push_back({frame, ghost.x, ghost.y});    // (the frame's own moment, not the tick's: it's drawn as it stands)
        }
        last_frame = frame;
        relay::Sample t;
        if (!play.at(now + CLOCK_GAP, t)) continue;
        targets.push_back({now, t.x, t.y});
        ghost.steer(t);
    }
    measure(p, targets, r.target, SETTLE, hitches);
    measure(p, ghosts, r.ghost, SETTLE, hitches);
    return r;
}

// An enemy as the host's AI moves it: chases, stops to strike, sidesteps, now and then a dash.
inline Path enemy_path(double seconds, uint32_t seed) {
    std::mt19937 rng(seed);
    const auto pick = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(rng); };
    std::vector<Leg> legs;
    double total = 0, heading = 0;
    const auto add = [&](Leg leg) {
        legs.push_back(leg);
        total += leg.ms;
    };
    add({500, 0, 0, START, HARD});
    while (total < seconds * 1000) {
        heading = pick(-180, 180);
        add({pick(1000, 2500), heading, pick(350, 450), 3000, QUICK, pick(-30, 30)});
        if (pick(0, 1) < 0.3) add({pick(300, 500), heading + (pick(0, 1) < 0.5 ? 90 : -90), 200, QUICK, QUICK});
        if (pick(0, 1) < 0.2) add({pick(250, 350), heading, 800, 20000, 20000});
        add({pick(500, 1500), heading, 0, START, HARD});
    }
    return walk_legs(legs);
}

// How an enemy copy follows on the guest (coop.lua's readEnemies, puppets.lua's steer): one line every every_ms from the
// host's frames, sent with the next packet (within the relay's 5 ms tick), read at the start of the guest's next tick and
// carried forward along its speed from then, for at most 200 ms. lead_ms is added to how far it's carried: a guess at
// how old the line already was when it was read, from the round trip or from the line's true age. Measured where the copy
// is steered to, not the copy itself: the enemies' own movement isn't known here.
inline Measures run_enemy(const Path& p, const Link& link, double every_ms, double fps, uint32_t seed,
                          const std::function<double(double rtt, double age)>& lead_ms) {
    constexpr double AHEAD_MS = 200, SETTLE = 3000;
    std::mt19937 rng(seed);
    std::uniform_real_distribution<double> unit(0, 1);
    struct Line {
        double at, sent, x, y, vx, vy;
        bool operator<(const Line& o) const { return at > o.at; }
    };
    std::priority_queue<Line> wire;
    Frames host(fps, seed * 3 + 1);
    double next_line = 0;
    for (double frame = 0; frame < p.length_ms(); frame += host.next()) {
        if (frame < next_line) continue;
        next_line = frame + every_ms;
        if (unit(rng) * 100 < link.loss) continue;
        double x, y, vx, vy;
        p.at(frame, x, y);
        p.velocity(frame, vx, vy);
        wire.push({frame + unit(rng) * 5 + link.rtt / 2 + unit(rng) * link.jitter, frame, x, y, vx, vy});
    }
    Frames guest(fps, seed * 7 + 5);
    std::vector<Shown> shown;
    bool have = false;
    Line r{};
    double read_at = 0;
    for (double frame = 0; frame < p.length_ms(); frame += guest.next()) {
        const double now = frame + guest.tick_offset();
        while (!wire.empty() && wire.top().at <= now) {
            r = wire.top();
            read_at = now;
            have = true;
            wire.pop();
        }
        if (!have) continue;
        const double ahead = std::min(now - read_at + lead_ms(link.rtt + link.jitter, read_at - r.sent), AHEAD_MS) / 1000;
        shown.push_back({now, r.x + r.vx * ahead, r.y + r.vy * ahead});
    }
    Measures m;
    measure(p, shown, m, SETTLE);
    return m;
}

}  // namespace lab
