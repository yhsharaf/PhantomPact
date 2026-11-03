// Turns the partner's samples, which arrive late and unevenly, into a smooth path: the ghost plays them a little in the
// past, just far enough that the next sample has arrived three times in four, and that distance follows the connection.
// The rest of the time it guesses ahead from the sender's speed, which only a sudden stop or turn proves wrong. The two
// PCs' clocks are never compared: the fastest trip seen lately is taken as "on time", and everything is measured from
// that. Plain logic with no Windows calls, so relay_cli can test it against simulated connections (latency.hpp is the
// bench that chose these numbers).
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>
#include <vector>

namespace relay {

struct Sample {
    uint32_t ms = 0;            // the sender's clock when the game read it
    float x = 0, y = 0, z = 0, yaw = 0;
    float vx = 0, vy = 0, vz = 0;
    float hp = 0, max_hp = 0;
    uint32_t map = 0;           // hash of the area's name
    uint16_t flags = 0;
};

constexpr uint16_t FLAG_GROUNDED = 1, FLAG_CUTSCENE = 2;   // sent by the mod
constexpr uint16_t FLAG_JUMP = 0x4000;                     // set here: this sample teleported, don't blend into it
constexpr uint16_t FLAG_STALE = 0x8000;                    // set here: nothing new for longer than it can guess ahead

inline float shortest_turn(float from, float to) {
    float d = std::fmod(to - from + 540.0f, 360.0f);
    if (d < 0) d += 360.0f;
    return d - 180.0f;
}

class Timeline {
public:
    static constexpr size_t KEEP = 96;
    static constexpr size_t LATE_SAMPLES = 90;           // about 1.5 s of arrivals
    static constexpr int FASTEST_BUCKETS = 8;
    static constexpr double FASTEST_BUCKET_MS = 750;     // so the fastest trip is remembered for 6 s
    static constexpr double MIN_DELAY_MS = 4, MAX_DELAY_MS = 220;
    static constexpr double EXTRAPOLATE_MS = 160;        // past this it stops guessing and holds the last place
    static constexpr double ON_TIME_SHARE = 0.75;        // played far enough behind that this share of samples are there in time
    static constexpr double GUESS_MS = 3;                // the last ms before one is due are guessed: less than a stop slides
    static constexpr double CARRIED_SPAN_MS = 20;        // this much of the path, played or not, says whether the sender is carried
    static constexpr double CARRIED_CM_S = 150;
    static constexpr double CARRIED_STEADY_CM_S = 200;   // two samples' speeds further apart than this: the sender's own doing
    static constexpr double JUMP_CM = 900;               // this far between samples, and faster than any move: a teleport
    static constexpr double JUMP_SPEED_CM_S = 4000;
    static constexpr double RESET_MS = 1500;             // play position this far off: the sender's clock restarted
    static constexpr double CLOCK_BACK_MS = 400;         // samples this far behind the newest are never a late packet...
    static constexpr int CLOCK_BACK_SAMPLES = 3;         // ...once several come in a row: the sender's clock went back

    Timeline() { clear(); }

    void clear() {
        samples_.clear();
        late_.clear();
        waits_.clear();
        late_at_ = 0;
        have_offset_ = false;
        bucket_start_ = 0;
        buckets_.fill(1e18);
        fastest_ = 0;
        jitter_ = 0;
        need_ = 0;
        last_arrival_ = 0;
        last_at_ = 0;
        played_ = 0;
        clock_back_ = 0;
    }

    void push(const Sample& sent, double arrived_ms) {
        Sample s = sent;
        s.flags &= ~(FLAG_JUMP | FLAG_STALE);        // these two are this class's own, never the sender's
        if (!samples_.empty() && static_cast<double>(s.ms) + CLOCK_BACK_MS < samples_.back().ms) {
            if (++clock_back_ >= CLOCK_BACK_SAMPLES) clear();   // nothing measured against the old clock means anything now
        } else {
            clock_back_ = 0;
        }
        const double trip = arrived_ms - static_cast<double>(s.ms);
        track_fastest(trip, arrived_ms);
        // How long after the sample before it this one came, on the fastest trip's clock: how far behind the play must be
        // for it to be there in time. (A pause over 200 ms is the sender standing still in a load, not a gap to wait out.)
        const double gap = !samples_.empty() && s.ms > samples_.back().ms ? static_cast<double>(s.ms - samples_.back().ms) : 0;
        note_late(trip - fastest_, (gap < 200 ? gap : 0) + trip - fastest_);
        last_arrival_ = arrived_ms;
        if (!samples_.empty()) {
            const Sample& newest = samples_.back();
            if (s.ms == newest.ms) return;
            if (s.ms > newest.ms) {
                if (is_jump(newest, s)) s.flags |= FLAG_JUMP;
                samples_.push_back(s);
            } else {
                // Arrived out of order: useful only if it's still ahead of what has been played.
                if (static_cast<double>(s.ms) <= played_) return;
                auto at = std::lower_bound(samples_.begin(), samples_.end(), s,
                                           [](const Sample& a, const Sample& b) { return a.ms < b.ms; });
                if (at != samples_.end() && at->ms == s.ms) return;
                at = samples_.insert(at, s);
                // It may be the sample on either side of a teleport: the jump belongs wherever the path really broke.
                if (at != samples_.begin()) mark_jump(*(at - 1), *at);
                if (at + 1 != samples_.end()) mark_jump(*at, *(at + 1));
            }
        } else {
            samples_.push_back(s);
        }
        while (samples_.size() > KEEP) samples_.pop_front();
    }

    // Where the partner was, on the path as it's being played. False until the first sample arrives.
    bool at(double now_ms, Sample& out) {
        if (samples_.empty()) return false;
        const double step = last_at_ > 0 ? std::clamp(now_ms - last_at_, 0.0, 100.0) : 0.0;
        last_at_ = now_ms;
        const double want = fastest_ + target_delay();
        if (!have_offset_ || std::fabs(want - offset_) > RESET_MS) {
            offset_ = want;
            have_offset_ = true;
        }
        // Eased in: more delay quickly (a spike is here now), less delay slowly (the ghost mustn't speed up visibly).
        offset_ += std::clamp(want - offset_, -step * 0.06, step * 0.25);
        const double t = now_ms - offset_;
        played_ = t;

        const Sample& newest = samples_.back();
        if (t >= newest.ms) {
            out = newest;
            carried(out);
            const double over = t - newest.ms;
            const double ahead = std::min(over, EXTRAPOLATE_MS) / 1000.0;
            out.x += static_cast<float>(out.vx * ahead);
            out.y += static_cast<float>(out.vy * ahead);
            if (!(newest.flags & FLAG_GROUNDED)) out.z += static_cast<float>(newest.vz * ahead);
            if (over > EXTRAPOLATE_MS) {
                out.flags |= FLAG_STALE;
                out.vx = out.vy = out.vz = 0;
            }
            return true;
        }
        size_t i = 0;
        while (i + 1 < samples_.size() && samples_[i + 1].ms <= t) i++;
        // What's been played is needed again only to tell whether the sender is carried (see carried): that much is kept.
        while (i > 0 && static_cast<double>(samples_[1].ms) + CARRIED_SPAN_MS <= t) {
            samples_.pop_front();
            i--;
        }
        const Sample& a = samples_[i];
        if (i + 1 >= samples_.size() || t < a.ms) {
            out = a;
            return true;
        }
        const Sample& b = samples_[i + 1];
        const double dt = static_cast<double>(b.ms - a.ms);
        if (b.flags & FLAG_JUMP) {
            out = a;                         // holds until the jump's moment comes, then lands in one step
            return true;
        }
        const double f = (t - a.ms) / dt;
        out = b;
        out.ms = static_cast<uint32_t>(t);
        out.x = lerp(a.x, b.x, f);
        out.y = lerp(a.y, b.y, f);
        out.z = lerp(a.z, b.z, f);
        out.yaw = a.yaw + static_cast<float>(shortest_turn(a.yaw, b.yaw) * f);
        // The sender's own speed, eased from one sample to the next. The step between two stamps is no measure of it: the
        // mod's tick comes at another moment of each frame, and the speed worked out from that swung by a fifth from sample
        // to sample, straight into the ghost's walk.
        out.vx = lerp(a.vx, b.vx, f);
        out.vy = lerp(a.vy, b.vy, f);
        out.vz = lerp(a.vz, b.vz, f);
        carried(out);
        return true;
    }

    double delay_ms() const { return have_offset_ ? offset_ - fastest_ : 0; }
    double jitter_ms() const { return jitter_; }
    double silence_ms(double now_ms) const { return last_arrival_ > 0 ? now_ms - last_arrival_ : 1e9; }

private:
    static float lerp(float a, float b, double f) { return static_cast<float>(a + (b - a) * f); }

    static bool is_jump(const Sample& a, const Sample& b) {
        const double dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
        const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
        const double dt = std::max(1.0, static_cast<double>(b.ms - a.ms));
        return d > JUMP_CM && d * 1000.0 / dt > JUMP_SPEED_CM_S;
    }

    static void mark_jump(const Sample& a, Sample& b) {
        if (is_jump(a, b)) b.flags |= FLAG_JUMP;
        else b.flags &= ~FLAG_JUMP;
    }

    double target_delay() const {
        return std::clamp(need_ - GUESS_MS, MIN_DELAY_MS, MAX_DELAY_MS);
    }

    // The samples kept moved further, or otherwise, than their own steady speeds say: the sender is carried (a lift,
    // something they're attached to, a speed the game didn't give). Then the path's own speed over them is the one to
    // follow. Never across a teleport, and not while the speeds themselves change: a stop or a turn inside a gap between
    // two samples puts their average off the path too.
    void carried(Sample& out) const {
        const Sample& a = samples_.front();
        const Sample& last = samples_.back();
        const double span = static_cast<double>(last.ms - a.ms);
        if (span < CARRIED_SPAN_MS) return;
        double said_x = 0, said_y = 0;
        for (size_t i = 0; i + 1 < samples_.size(); i++) {
            const Sample &from = samples_[i], &to = samples_[i + 1];
            if ((to.flags & FLAG_JUMP) || std::hypot(to.vx - from.vx, to.vy - from.vy) > CARRIED_STEADY_CM_S) return;
            const double half = static_cast<double>(samples_[i + 1].ms - samples_[i].ms) / 2000;
            said_x += (samples_[i].vx + samples_[i + 1].vx) * half;
            said_y += (samples_[i].vy + samples_[i + 1].vy) * half;
        }
        const double went_x = last.x - a.x, went_y = last.y - a.y;
        const double off = std::hypot(went_x - said_x, went_y - said_y) * 1000 / span;
        if (off <= std::max(CARRIED_CM_S, 0.3 * std::hypot(went_x, went_y) * 1000 / span)) return;
        out.vx = static_cast<float>(went_x * 1000 / span);
        out.vy = static_cast<float>(went_y * 1000 / span);
    }

    void track_fastest(double trip, double now_ms) {
        if (bucket_start_ == 0) bucket_start_ = now_ms;
        if (now_ms - bucket_start_ >= FASTEST_BUCKET_MS * FASTEST_BUCKETS) {    // a long silence: nothing kept is recent
            buckets_.fill(1e18);
            bucket_start_ = now_ms;
        }
        while (now_ms - bucket_start_ >= FASTEST_BUCKET_MS) {
            bucket_start_ += FASTEST_BUCKET_MS;
            std::rotate(buckets_.begin(), buckets_.begin() + 1, buckets_.end());
            buckets_.back() = 1e18;
        }
        buckets_.back() = std::min(buckets_.back(), trip);
        fastest_ = *std::min_element(buckets_.begin(), buckets_.end());
    }

    // Over the last LATE_SAMPLES arrivals: the 90th percentile of how late they were, for the status line, and how far
    // behind the play must be for ON_TIME_SHARE of them to be there in time. Measured that way a skipped frame, a lost
    // sample or one late spike costs no delay, and a connection that is often late does.
    void note_late(double late, double wait) {
        if (late_.size() < LATE_SAMPLES) {
            late_.push_back(late);
            waits_.push_back(wait);
        } else {
            late_[late_at_ % LATE_SAMPLES] = late;
            waits_[late_at_ % LATE_SAMPLES] = wait;
        }
        late_at_++;
        if (late_at_ % 8 == 0 || late_.size() < 8) {
            jitter_ = share_of(late_, 0.9);
            need_ = share_of(waits_, ON_TIME_SHARE);
        }
    }

    double share_of(const std::vector<double>& values, double share) {
        scratch_ = values;
        auto at = scratch_.begin() + static_cast<long>(std::min(scratch_.size() - 1, static_cast<size_t>(scratch_.size() * share)));
        std::nth_element(scratch_.begin(), at, scratch_.end());
        return *at;
    }

    std::deque<Sample> samples_;
    std::vector<double> late_, waits_, scratch_;
    size_t late_at_ = 0;
    std::array<double, FASTEST_BUCKETS> buckets_{};
    double bucket_start_ = 0;
    double fastest_ = 0;
    double jitter_ = 0, need_ = 0;
    double offset_ = 0;
    bool have_offset_ = false;
    double last_arrival_ = 0, last_at_ = 0, played_ = 0;
    int clock_back_ = 0;
};

}  // namespace relay
