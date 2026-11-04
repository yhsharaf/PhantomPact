// Four or six players: the beta behind PartySize = 4 (or FourPlayers = On), and PartySize = 6 (experimental). Only a host with
// that setting runs this: otherwise run() goes to one Relay
// and nothing here is reached. Included by relay.hpp, partway down: it needs what comes before it.
//
// The shape is EXACG's (PR #11): a star. A guest only ever talks to the host, and the host passes on what the others need.
// Each guest has a whole Relay of its own on the host, so its session, lanes and round trip are its alone, exactly as with two
// players, and a guest's end of the connection is the one it always had. All of them run on the relay thread. What's added:
//   - what the host's game posts goes into every guest's Mailbox (one guest's: post_to)
//   - what a guest says reaches the host's game as "@<slot> <event>", and the other guests the same way, so everyone knows
//     who it came from. Only a host's relay writes that tag, so a guest can't speak for anyone else
//   - where a guest is goes to the others as SEC_PLAYER, from the relay thread: the host's game can be standing still in a load
// Slots: 1 is the host, 2 to size_ the guests in the order they came. The hello tells a guest its own, and the size.
#pragma once
#include <string_view>

namespace relay {

// The host's socket as one guest's Relay sees it. Party reads it for all of them, so there's nothing for a Relay to receive.
class GuestLink : public Link {
public:
    explicit GuestLink(Link& shared) : shared_(shared) {}
    void send(const Addr& to, const std::string& data) override {
        sent_bytes += data.size();
        shared_.send(to, data);
    }
    std::vector<std::pair<Addr, std::string>> receive() override { return {}; }
    void wait(double, HANDLE) override {}
    Route route(const Addr& a) override { return shared_.route(a); }
    std::string problem() override { return shared_.problem(); }
    std::string describe(const Addr& a) override { return shared_.describe(a); }
    std::string describe_self() override { return shared_.describe_self(); }
    const char* via() override { return shared_.via(); }

    void copy_counts() {
        filtered = shared_.filtered;
        refused = shared_.refused;
    }

    long long sent_bytes = 0;

private:
    Link& shared_;
};

class Party : public Hub {
public:
    Party(const std::wstring& dir, std::unique_ptr<Link> link, const std::string* secret, const Ini& ini, const std::string& version,
          std::function<void(const std::string&)> log, Mailbox& box = mail)
        : link_(std::move(link)), box_(box), version_(clean_token(version)), size_(std::max(party_size(ini), 4)) {
        for (int slot = FIRST_GUEST_SLOT; slot <= size_; slot++) {
            auto guest = std::make_unique<Guest>();
            guest->slot = slot;
            auto sub = std::make_unique<GuestLink>(*link_);
            guest->link = sub.get();
            guest->relay = std::make_unique<Relay>("host", dir, std::move(sub), secret, ini, version, log, guest->box);
            guest->relay->join_party(this, slot, size_);
            guests_.push_back(std::move(guest));
        }
        box_.set_party(size_, HOST_SLOT);
    }

    void tick(double now) {
        for (auto& [addr, packet] : link_->receive()) on_packet(addr, packet, now);
        Mailbox::Outgoing out;
        box_.take_outgoing(out);
        for (auto& guest : guests_) guest->box.absorb(out, guest->relay->has_partner());
        for (auto& [slot, text] : out.direct)
            if (slot >= FIRST_GUEST_SLOT && slot <= size_) guests_[slot - FIRST_GUEST_SLOT]->box.post_sure(std::move(text));
        for (auto& guest : guests_) guest->relay->tick(now);
    }

    void wait() { link_->wait(TICK, box_.wake); }

    // One packet off the wire. Public for the tests.
    void on_packet(const Addr& from, const std::string& packet, double now) {
        if (Guest* guest = slot_for(from, now)) guest->relay->on_packet(from, packet, now);
        else turned_away_++;
    }

    // The first guest here speaks for the connection, as the partner does with two players. The end of the line says the rest:
    // how many there are, what each guest's map is, who's on another version, and what this PC sends.
    std::string status(double now) {
        std::string line, versions, maps;
        std::vector<std::string> differ;
        int rank = -1, here = 0;
        long long rejected = 0, sent = 0;
        for (auto& guest : guests_) rejected += guest->relay->rejected();
        for (auto& guest : guests_) {
            guest->link->copy_counts();
            sent += guest->link->sent_bytes;
            // Asked of each: it counts its losses from one call to the next.
            std::string one = guest->relay->status(now, rejected - guest->relay->rejected());
            const bool in = guest->relay->here(now);
            const int mine = in ? 2 : guest->relay->heard_of_someone() ? 1 : 0;
            here += in ? 1 : 0;
            if (mine > rank) {
                rank = mine;
                line = std::move(one);
            }
            const std::string slot = std::to_string(guest->slot);
            const std::string& version = guest->relay->partner_version();
            if (!version.empty() && version != version_) versions += (versions.empty() ? "" : ",") + slot + ":" + version;
            if (in) {
                if (!guest->relay->partner_map().empty()) maps += " map" + slot + "=" + guest->relay->partner_map();
                for (const std::string& key : guest->relay->mismatch())
                    if (std::find(differ.begin(), differ.end(), key) == differ.end()) differ.push_back(key);
            }
        }
        std::string mismatch;
        for (const std::string& key : differ) mismatch += (mismatch.empty() ? "" : ",") + key;
        replace_field(line, "mismatch", mismatch.empty() ? "-" : mismatch);
        const double seconds = now - rate_from_;
        const long long rate = seconds > 0 ? static_cast<long long>((sent - rate_bytes_) / seconds / 1024) : 0;
        rate_from_ = now;
        rate_bytes_ = sent;
        return line + " players=" + std::to_string(size_) + " slot=" + std::to_string(HOST_SLOT) + " guests=" + std::to_string(here) +
               " turned_away=" + std::to_string(turned_away_) + " upload_kb_s=" + std::to_string(rate) + maps +
               (versions.empty() ? "" : " other_versions=" + versions);
    }

    std::string describe_self() { return link_->describe_self() + ", up to " + std::to_string(size_ - HOST_SLOT) + " guests"; }

    // Hub: what each guest's Relay hears.

    void on_sample(int slot, const Sample& s, double arrived_ms) override {
        box_.on_player(slot, s, arrived_ms);
        for (auto& guest : guests_)
            if (guest->slot != slot) guest->relay->queue_player(slot, s);
    }

    bool on_sure(int slot, const std::string& text) override {
        if (!one_line(text)) return true;       // confirmed and dropped: sent again it would only be dropped again
        const std::string tagged = tag(slot) + text;
        // (Tagged past what a line may be: the host's game got it whole and the other guests cut, its end gone. Dropped,
        // as one line of two would be.)
        if (tagged.size() > MAX_TEXT) return true;
        if (!box_.on_event(tagged)) return false;
        if (!for_host_alone(text))
            for (auto& guest : guests_)
                if (guest->slot != slot && guest->relay->has_partner()) guest->box.post_sure(tagged);
        return true;
    }

    void on_quick(int slot, std::string_view text, double arrived_ms) override {
        if (!one_line(text)) return;
        const std::string tagged = tag(slot) + std::string(text);
        if (tagged.size() > MAX_TEXT) return;
        box_.on_quick(tagged, arrived_ms);
        for (auto& guest : guests_)
            if (guest->slot != slot && guest->relay->has_partner()) guest->box.post_quick(tagged);
    }

    // A guest started over, or a new one took the slot: the other guests hear it too, or they kept the one before's state
    // for that slot until the new one happened to say otherwise.
    void on_restart(int slot) override {
        box_.on_player_restart(slot);
        for (auto& guest : guests_)
            if (guest->slot != slot && guest->relay->has_partner()) guest->box.post_sure(tag(slot) + "S");
    }

private:
    struct Guest {
        ~Guest() { CloseHandle(box.wake); }     // (the one Mailbox that's not for the life of the game)
        int slot = 0;
        Mailbox box;
        GuestLink* link = nullptr;       // the Relay owns it
        std::unique_ptr<Relay> relay;
    };

    static std::string tag(int slot) { return "@" + std::to_string(slot) + " "; }

    // A hit on an enemy is between that guest and the host: the others see its health go down.
    static bool for_host_alone(std::string_view text) { return text.rfind("D ", 0) == 0; }

    // The tag goes in front of one event: with a line break in it, what's after that would pass for a line of its own, with
    // no tag or anyone's.
    static bool one_line(std::string_view text) { return text.find_first_of("\r\n") == std::string_view::npos; }

    static void replace_field(std::string& line, const std::string& key, const std::string& value) {
        const std::string name = " " + key + "=";
        const size_t at = line.find(name);
        if (at == std::string::npos) return;
        const size_t from = at + name.size();
        line.replace(from, line.find(' ', from) - from, value);
    }

    // Whoever this is talking to already; else a free slot; else one whose guest has gone silent, as a host with one guest
    // takes another sender only then.
    Guest* slot_for(const Addr& from, double now) {
        for (auto& guest : guests_)
            if (guest->relay->partner_is(from)) return guest.get();
        for (auto& guest : guests_)
            if (!guest->relay->has_partner()) return guest.get();
        for (auto& guest : guests_)
            if (!guest->relay->here(now)) return guest.get();
        return nullptr;
    }

    std::unique_ptr<Link> link_;
    Mailbox& box_;
    std::string version_;
    int size_;                                  // players at most, this host too: 4 or 6
    std::vector<std::unique_ptr<Guest>> guests_;
    long long turned_away_ = 0, rate_bytes_ = 0;
    double rate_from_ = 0;
};

}  // namespace relay
