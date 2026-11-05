// The relay inside the game. UE4SS Lua can't open sockets, so this runs on its own thread in main.dll (main_dll.cpp),
// and the mod reaches it through direct calls (lua_link.hpp) with nothing on disk between them: the game thread only
// copies a few bytes in or out of the Mailbox here. relay_cli.cpp wraps it as a console tool for the tests.
//
// Protocol 3, one packet (all little-endian):
//   header   marker, protocol, flags, session, partner's session, sequence, time, echoed time, hold, acknowledgement
//   sections state (the player, newest wins) | sure and quick events (lanes.hpp) | enemy lines | hello
//            | another player, passed on by the host (only with more than two: party.hpp)
// A packet goes out the moment the game has something new, carrying whatever else is waiting, so an acknowledgement or
// an event never needs a packet of its own while the game is running.
#pragma once
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <timeapi.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "crypto.hpp"
#include "lanes.hpp"
#include "timeline.hpp"

namespace relay {

constexpr int PROTOCOL = 4;   // 4: parties of up to 6 (1.6.4): a 1.6.3 guest took a 6-player hello for two players
constexpr unsigned char MARKER = 0xA3;     // first byte of every packet: never '{' (protocol 2) or 'P' (a signed packet)
constexpr double TICK = 0.005;             // how often the relay looks at its timers when nothing else wakes it
constexpr double KEEPALIVE_EVERY = 0.25;   // the game thread can stand still (a load): the relay still says it's here
constexpr double PEER_TIMEOUT = 3.0;
constexpr double HELLO_EVERY = 2.0;
constexpr double PROBE_EVERY = 1.0;
constexpr double ACK_WAIT = 0.004;         // a bare acknowledgement goes out if no packet does within this time
constexpr double QUICK_GAP = 0.040;        // a quick event's repeats go this long and then twice that after: at 0, 40, 120 ms.
                                           // A burst of Wi-Fi loss over two frames took all three a frame apart.
constexpr double RETRY_MIN = 0.03, RETRY_MAX = 0.5;
constexpr size_t MAX_PACKET = 1100;        // with a signature, still under a VPN's 1280-byte limit
constexpr size_t MAX_TEXT = 900;           // one event or enemy line
constexpr int MAX_PACKETS_AT_ONCE = 6;
constexpr size_t MAX_ENEMY_LINES = 128;    // waiting to go: the oldest are out of date anyway
constexpr size_t MAX_INBOX_BYTES = 1 << 20;
constexpr size_t MAX_QUICK_WAITING = 256;
constexpr int MAX_PACKETS_PER_RECEIVE = 256;
constexpr int HOST_SLOT = 1, FIRST_GUEST_SLOT = 2, MAX_SLOT = 6;   // who's who with more than two players (party.hpp)
constexpr double PLAYERS_EVERY = 1.0 / 60;  // where the others are goes to a guest this often at most: it mostly rides along

inline std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

inline std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
    return s;
}

inline double monotonic() {
    static const double freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return c.QuadPart / freq;
}

// Milliseconds since the mod started: what packets are stamped with, and it can't wrap 32 bits within a session.
inline double clock_ms() {
    static const double start = monotonic();
    return (monotonic() - start) * 1000.0;
}

inline double wall_seconds() {
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    return (u.QuadPart - 116444736000000000ULL) / 1e7;
}

// Lua's text mode writes CRLF: lines are normalized here, as Python's text mode does.
inline std::string read_text(const std::wstring& path) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return {};
    std::string out;
    char buf[16384];
    DWORD got = 0;
    while (ReadFile(h, buf, sizeof buf, &got, nullptr) && got > 0) out.append(buf, got);
    CloseHandle(h);
    if (out.find('\r') != std::string::npos) {
        std::string clean;
        clean.reserve(out.size());
        for (size_t i = 0; i < out.size(); i++) {
            if (out[i] == '\r') {
                if (i + 1 < out.size() && out[i + 1] == '\n') continue;
                clean.push_back('\n');
            } else {
                clean.push_back(out[i]);
            }
        }
        out.swap(clean);
    }
    return out;
}

// False if the file couldn't be written this time; the next tick writes fresh data anyway. The mod may have the
// file open for a moment, and Windows can briefly refuse a rename for other reasons: retry, then skip.
inline bool write_atomic(const std::wstring& path, const std::string& text) {
    const std::wstring tmp = path + L".tmp";
    for (int attempt = 0; attempt < 5; attempt++) {
        HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD wrote = 0;
            bool ok = text.empty() ||
                      (WriteFile(h, text.data(), static_cast<DWORD>(text.size()), &wrote, nullptr) &&
                       wrote == text.size());
            CloseHandle(h);
            if (ok && MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) return true;
        }
        Sleep(2 * (attempt + 1));
    }
    return false;
}

// False if the lines couldn't be appended (the caller keeps them and retries next time).
inline bool append_lines(const std::wstring& path, const std::vector<std::string>& lines) {
    std::string text;
    for (const auto& line : lines) {
        text += line;
        text.push_back('\n');
    }
    for (int attempt = 0; attempt < 5; attempt++) {
        HANDLE h = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
                               OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD wrote = 0;
            bool ok = WriteFile(h, text.data(), static_cast<DWORD>(text.size()), &wrote, nullptr) &&
                      wrote == text.size();
            CloseHandle(h);
            if (ok) return true;
        }
        Sleep(2 * (attempt + 1));
    }
    return false;
}

inline std::string strip(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) a++;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) b--;
    return s.substr(a, b - a);
}

// Where a partner can be: Tailscale (100.64.0.0/10), home networks, this PC, and the Hamachi (25/8) and Radmin
// (26/8) VPN ranges. The host takes packets only from these unless AllowAnyAddress is on.
inline bool address_allowed(uint32_t ip) {
    static const struct { uint32_t net, mask; } nets[] = {
        {0x64400000, 0xFFC00000}, {0x0A000000, 0xFF000000}, {0xAC100000, 0xFFF00000}, {0xC0A80000, 0xFFFF0000},
        {0xA9FE0000, 0xFFFF0000}, {0x7F000000, 0xFF000000}, {0x19000000, 0xFF000000}, {0x1A000000, 0xFF000000}};
    for (const auto& n : nets)
        if ((ip & n.mask) == n.net) return true;
    return false;
}

// Optional shared secret (Secret = ... in PhantomPact.ini).
// packet = MAGIC | role (1) | session (8) | counter (8) | time ms (8) | payload | HMAC-SHA256 (32)
class Auth {
public:
    static constexpr char MAGIC[] = "PPA1";
    static constexpr size_t HEADER = 4 + 1 + 8 + 8 + 8;
    static constexpr size_t TAG = 32;
    static constexpr double REPLAY_WINDOW_S = 120.0;
    static constexpr size_t SESSIONS_KEPT = 24;   // (2 x 6 players and then some: with 8, guests rejoining pushed a session out inside its window)
    static constexpr uint64_t COUNTERS_KEPT = 64;      // the network can reorder: a late packet isn't a replay
    long long clock_off = 0;        // packets signed right but sent at a time over the window from this PC's clock

    Auth(const std::string& secret, const std::string& role) {
        std::string master = crypto::scrypt(secret, "PhantomPact/relay/1", 1 << 14, 8, 32);
        key_ = crypto::hmac_sha256(master, "packet-mac");
        role_ = role == "host" ? 'H' : 'C';
        session_.resize(8);
        if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, reinterpret_cast<PUCHAR>(session_.data()), 8,
                                            BCRYPT_USE_SYSTEM_PREFERRED_RNG)))
            throw std::runtime_error("no system random numbers for the Secret");
    }

    static void put_u64(std::string& out, uint64_t v) {
        for (int i = 7; i >= 0; i--) out.push_back(static_cast<char>(v >> (8 * i)));
    }
    static uint64_t get_u64(const char* p) {
        uint64_t v = 0;
        for (int i = 0; i < 8; i++) v = (v << 8) | static_cast<unsigned char>(p[i]);
        return v;
    }

    std::string seal(const std::string& payload) {
        std::string body(MAGIC, 4);
        body.push_back(role_);
        body += session_;
        put_u64(body, ++counter_);
        put_u64(body, static_cast<uint64_t>(wall_seconds() * 1000));
        body += payload;
        return body + crypto::hmac_sha256(key_, body);
    }

    // The payload of a valid packet from the other side, or nothing.
    std::optional<std::string> open(const std::string& data) {
        if (data.size() < HEADER + TAG || data.compare(0, 4, MAGIC, 4) != 0) return std::nullopt;
        std::string body = data.substr(0, data.size() - TAG);
        std::string expected = crypto::hmac_sha256(key_, body);
        unsigned char diff = 0;
        for (size_t i = 0; i < TAG; i++) diff |= static_cast<unsigned char>(expected[i] ^ data[body.size() + i]);
        if (diff) return std::nullopt;
        std::string session = body.substr(5, 8);
        uint64_t counter = get_u64(body.data() + 13);
        uint64_t sent_ms = get_u64(body.data() + 21);
        if (body[4] == role_ || session == session_) return std::nullopt;
        if (std::fabs(wall_seconds() * 1000 - static_cast<double>(sent_ms)) > REPLAY_WINDOW_S * 1000) {
            // Signed with the right Secret and only the time wrong: the two PCs' clocks differ by more than the window.
            // Counted, for the status to say so: before, they just never connected, with nothing to tell why.
            clock_off++;
            return std::nullopt;
        }
        Seen entry{session, counter, 1};
        auto it = std::find_if(seen_.begin(), seen_.end(), [&](const Seen& s) { return s.session == session; });
        if (it != seen_.end()) {
            entry = *it;
            if (counter > entry.top) {
                const uint64_t ahead = counter - entry.top;
                entry.bits = ahead >= COUNTERS_KEPT ? 0 : entry.bits << ahead;
                entry.bits |= 1;
                entry.top = counter;
            } else {
                const uint64_t back = entry.top - counter;
                if (back >= COUNTERS_KEPT || (entry.bits >> back) & 1) return std::nullopt;
                entry.bits |= 1ull << back;
            }
            seen_.erase(it);
        }
        seen_.push_back(std::move(entry));
        while (seen_.size() > SESSIONS_KEPT) seen_.erase(seen_.begin());
        return body.substr(HEADER);
    }

private:
    struct Seen {
        std::string session;
        uint64_t top = 0, bits = 0;      // highest counter accepted; bit n set = top - n was accepted too
    };

    std::string key_, session_;
    char role_ = 'C';
    uint64_t counter_ = 0;
    std::vector<Seen> seen_;             // oldest first
};

using Ini = std::map<std::string, std::string>;

inline std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// Key (lowercase) -> value from PhantomPact.ini; ';' and '#' start comments. Empty if there's no file.
inline Ini read_ini(const std::wstring& path) {
    Ini out;
    std::string text = read_text(path);
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = strip(text.substr(pos, end - pos));
        pos = end + 1;
        size_t eq = line.find('=');
        if (line.empty() || line[0] == ';' || line[0] == '#' || eq == std::string::npos) continue;
        out[lower(strip(line.substr(0, eq)))] = strip(line.substr(eq + 1));
    }
    return out;
}

// A peer-sent value made safe for the space-separated status line (no spaces, newlines or '=').
inline std::string clean_token(const std::string& value, size_t limit = 32) {
    std::string out;
    for (char c : value) {
        if (std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '.' || c == '-') out.push_back(c);
        if (out.size() == limit) break;
    }
    return out.empty() ? "?" : out;
}

inline const char* const SHARED_SETTINGS[] = {"coopenemyhealth", "coopenemyposture", "pvp", "pvpdamage",
                                              "pvpparryposture", "connect", "revive"};

inline bool is_shared_setting(const std::string& key) {
    return std::any_of(std::begin(SHARED_SETTINGS), std::end(SHARED_SETTINGS), [&](const char* k) { return key == k; });
}

// How many players a host takes: PartySize 2, 4 or 6 (6 is experimental), or the older FourPlayers = On for 4. Anything
// else is 2: one guest, no party.
inline int party_size(const Ini& ini) {
    auto size = ini.find("partysize");
    if (size != ini.end()) {
        const long n = std::strtol(size->second.c_str(), nullptr, 10);
        if (n >= 6) return 6;
        if (n >= 4) return 4;
        if (n >= 2) return 2;
    }
    auto four = ini.find("fourplayers");
    if (four != ini.end() && lower(four->second) == "on") return 4;
    return 2;
}

// An IPv4 address and port (host byte order), or a SteamID64.
struct Addr {
    uint32_t ip = 0;
    uint16_t port = 0;
    uint64_t steam = 0;
    bool operator==(const Addr& o) const { return ip == o.ip && port == o.port && steam == o.steam; }
    bool operator!=(const Addr& o) const { return !(*this == o); }
};

class Link {
public:
    virtual ~Link() = default;
    virtual void send(const Addr& to, const std::string& data) = 0;
    virtual std::vector<std::pair<Addr, std::string>> receive() = 0;
    virtual void wait(double seconds, HANDLE wake) = 0;    // until a packet may be waiting, wake is set, or time's up
    virtual std::vector<Addr> candidates() { return {}; }  // guests with no host yet ping these
    struct Route {
        const char* kind = "-";    // "direct", "relay", or "-" if the link can't tell
        int ping_ms = -1;          // the link's own measure of the round trip, if it has one
    };
    virtual Route route(const Addr&) { return {}; }
    virtual std::string problem() { return ""; }           // the link's own words for its last failure, as one word
    virtual std::string describe(const Addr& a) = 0;
    virtual std::string describe_self() = 0;
    virtual const char* via() = 0;
    std::optional<Addr> peer;     // known up front (UDP guest, Steam guest given an id)
    long long filtered = 0;
    long long refused = 0;        // sends the link turned down
};

class UdpLink : public Link {
public:
    UdpLink(const std::string& role, const std::string& peer_host, int port, bool allow_any, bool this_pc_only)
        : allow_any_(allow_any) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) throw std::runtime_error("Winsock didn't start");
        sock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock_ == INVALID_SOCKET) throw std::runtime_error("couldn't open a UDP socket");
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(this_pc_only ? INADDR_LOOPBACK : INADDR_ANY);
        addr.sin_port = htons(static_cast<u_short>(role == "host" ? port : 0));
        if (bind(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0) {
            const int err = WSAGetLastError();
            closesocket(sock_);
            throw std::runtime_error("UDP port " + std::to_string(port) + (err == WSAEADDRINUSE ? " is in use on this PC" : " can't be used") +
                                     " (error " + std::to_string(err) + "): set another Port in PhantomPact.ini on both PCs");
        }
        if (role != "host") {
            // Resolved once (a Tailscale name works too): replies are matched against this exact address.
            addrinfo hints{};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_DGRAM;
            addrinfo* found = nullptr;
            if (getaddrinfo(peer_host.c_str(), nullptr, &hints, &found) != 0 || !found) {
                closesocket(sock_);
                throw std::runtime_error("couldn't find the host address " + peer_host);
            }
            Addr a;
            a.ip = ntohl(reinterpret_cast<sockaddr_in*>(found->ai_addr)->sin_addr.s_addr);
            a.port = static_cast<uint16_t>(port);
            freeaddrinfo(found);
            peer = a;
        }
        // Signalled the moment a packet lands, so the relay sleeps instead of polling. Makes the socket non-blocking.
        readable_ = WSACreateEvent();
        WSAEventSelect(sock_, readable_, FD_READ);
    }

    ~UdpLink() override {
        WSACloseEvent(readable_);
        closesocket(sock_);
        WSACleanup();
    }

    void send(const Addr& to, const std::string& data) override {
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(to.ip);
        addr.sin_port = htons(to.port);
        sendto(sock_, data.data(), static_cast<int>(data.size()), 0, reinterpret_cast<sockaddr*>(&addr), sizeof addr);
    }

    std::vector<std::pair<Addr, std::string>> receive() override {
        std::vector<std::pair<Addr, std::string>> out;
        static thread_local std::vector<char> buf(65536);
        for (int i = 0; i < MAX_PACKETS_PER_RECEIVE; i++) {
            sockaddr_in from{};
            int from_len = sizeof from;
            int n = recvfrom(sock_, buf.data(), static_cast<int>(buf.size()), 0, reinterpret_cast<sockaddr*>(&from), &from_len);
            if (n < 0) {
                int err = WSAGetLastError();
                // Windows reports ICMP "port unreachable" this way while the peer isn't running yet.
                if (err == WSAECONNRESET || err == WSAEMSGSIZE) continue;
                break;
            }
            Addr a;
            a.ip = ntohl(from.sin_addr.s_addr);
            a.port = ntohs(from.sin_port);
            if (peer && a != *peer) filtered++;      // a client listens to its host's exact address and port only
            else if (!peer && !allow_any_ && !address_allowed(a.ip)) filtered++;
            else out.emplace_back(a, std::string(buf.data(), n));
        }
        return out;
    }

    void wait(double seconds, HANDLE wake) override {
        HANDLE events[2] = {wake, readable_};
        // A socket event stays set until it's reset: left alone, this thread spins a whole core from the first packet on.
        // Reset before the read that follows, so a packet landing after that read sets it again.
        if (WaitForMultipleObjects(2, events, FALSE, static_cast<DWORD>(std::ceil(seconds * 1000))) == WAIT_OBJECT_0 + 1)
            WSAResetEvent(readable_);
    }

    std::string describe(const Addr& a) override {
        char s[32];
        std::snprintf(s, sizeof s, "%u.%u.%u.%u:%u", a.ip >> 24, (a.ip >> 16) & 255, (a.ip >> 8) & 255, a.ip & 255, a.port);
        return s;
    }

    std::string describe_self() override {
        sockaddr_in me{};
        int len = sizeof me;
        getsockname(sock_, reinterpret_cast<sockaddr*>(&me), &len);
        return "UDP " + std::to_string(ntohs(me.sin_port));
    }

    const char* via() override { return "udp"; }

private:
    SOCKET sock_ = INVALID_SOCKET;
    WSAEVENT readable_ = WSA_INVALID_EVENT;
    bool allow_any_;
};

// Between the game thread and the relay thread. Everything here is a quick copy under a lock neither side holds across
// anything slow, so the game can never wait on the network.
class Mailbox {
public:
    Mailbox() {
        InitializeSRWLock(&lock_);
        wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    }

    // A quick event waiting to go, and how old it already was when posted: a guest's, passed on by a party's host.
    struct Move {
        std::string text;
        double age_ms = 0;
    };

    struct Outgoing {
        bool have_sample = false, reset = false, map_changed = false;
        Sample sample;
        std::string map;
        std::vector<std::string> sure, enemies;
        std::vector<Move> quick;
        std::vector<std::pair<int, std::string>> direct;    // a party: slot, a sure event for that guest alone
    };

    // Game thread.

    void post_sample(const Sample& s) {
        {
            Lock hold(lock_);
            out_.sample = s;
            out_.have_sample = true;
        }
        SetEvent(wake);
    }

    void post_sure(std::string text) { post(out_.sure, std::move(text)); }

    void post_quick(std::string text, double age_ms = 0) {
        {
            Lock hold(lock_);
            keep(out_.quick, std::move(text), age_ms);
        }
        SetEvent(wake);
    }

    void post_enemy(std::string text) {
        Lock hold(lock_);
        keep(out_.enemies, std::move(text));
    }

    void post_map(std::string name) {
        {
            Lock hold(lock_);
            out_.map = std::move(name);
            out_.map_changed = true;
        }
        SetEvent(wake);
    }

    // Sync turned on: whatever waited was for nobody, and the partner gets told this is a new start.
    void reset() {
        {
            Lock hold(lock_);
            out_.reset = true;
            out_.sure.clear();
            out_.quick.clear();
            out_.enemies.clear();
            events_.clear();
            quick_.clear();
            enemies_.clear();
            timeline_.clear();
            for (Timeline& line : players_) line.clear();
        }
        SetEvent(wake);
    }

    bool partner(double now_ms, Sample& out, double& silence_ms, double& delay_ms) {
        Lock hold(lock_);
        silence_ms = timeline_.silence_ms(now_ms);
        delay_ms = timeline_.delay_ms();
        return timeline_.at(now_ms, out);
    }

    // A move that sat here through a long hitch on this PC is as stale as one that arrived late: dropped, not played in a
    // burst when the game comes back. The others go with how long ago the partner's game read them, in ms, in front:
    // "~<age> <event>", for the move to start that far in (coop.lua's processEvents takes it off).
    std::string take_events(double now_ms) {
        std::string out;
        Lock hold(lock_);
        out.swap(events_);
        for (const Waiting& q : quick_) {
            if (now_ms - q.arrived_ms > QUICK_WAIT_MS) continue;
            out += "~" + std::to_string(std::lround(q.age_ms + now_ms - q.arrived_ms)) + " ";
            out.append(q.text);
            out.push_back('\n');
        }
        quick_.clear();
        return out;
    }

    std::string take_enemies() {
        std::string out;
        Lock hold(lock_);
        out.swap(enemies_);
        return out;
    }

    std::string status() {
        Lock hold(lock_);
        return status_;
    }

    // Relay thread.

    void take_outgoing(Outgoing& into) {
        Lock hold(lock_);
        std::swap(into, out_);
    }

    void on_sample(const Sample& s, double arrived_ms) {
        Lock hold(lock_);
        timeline_.push(s, arrived_ms);
    }

    // False if the game hasn't read enough to leave room.
    bool on_event(std::string_view text) {
        Lock hold(lock_);
        if (events_.size() + text.size() > MAX_INBOX_BYTES) return false;
        events_.append(text);
        events_.push_back('\n');
        return true;
    }

    void on_quick(std::string_view text, double arrived_ms, double age_ms) {
        Lock hold(lock_);
        if (quick_.size() >= MAX_QUICK_WAITING) quick_.pop_front();
        quick_.push_back({arrived_ms, age_ms, std::string(text)});
    }

    void on_enemies(std::string_view text) {
        Lock hold(lock_);
        if (enemies_.size() + text.size() > MAX_INBOX_BYTES) enemies_.clear();   // nobody's reading: only the newest count
        enemies_.append(text);
        enemies_.push_back('\n');
    }

    void forget_partner() {
        Lock hold(lock_);
        timeline_.clear();
        enemies_.clear();
    }

    // S always gets in, past the limit too: it's how the game learns that the partner has to be told everything again.
    void on_partner_restart() {
        forget_partner();
        Lock hold(lock_);
        for (auto& line : players_) line.clear();     // (the host started over: its guests may come back in other slots)
        events_ += "S\n";
    }

    void set_status(std::string line) {
        Lock hold(lock_);
        status_ = std::move(line);
    }

    void link_numbers(double& jitter_ms, double& delay_ms) {
        Lock hold(lock_);
        jitter_ms = timeline_.jitter_ms();
        delay_ms = timeline_.delay_ms();
    }

    // A party (party.hpp). With two players none of this is used.

    // Game thread.

    void post_to(int slot, std::string text) {
        {
            Lock hold(lock_);
            if (out_.direct.size() < MAX_SURE_PENDING) out_.direct.emplace_back(slot, std::move(text));
        }
        SetEvent(wake);
    }

    bool player(int slot, double now_ms, Sample& out, double& silence_ms, double& delay_ms) {
        if (slot < FIRST_GUEST_SLOT || slot > MAX_SLOT) return false;
        Lock hold(lock_);
        Timeline& line = players_[slot - FIRST_GUEST_SLOT];
        silence_ms = line.silence_ms(now_ms);
        delay_ms = line.delay_ms();
        return line.at(now_ms, out);
    }

    bool party(int& players, int& slot) {
        Lock hold(lock_);
        players = party_players_;
        slot = party_slot_;
        return players != 0;
    }

    // Relay thread.

    void set_party(int players, int slot) {
        Lock hold(lock_);
        // (Slots handed out again, a host restarted: what was heard under a slot was someone else's, this guest's own too.)
        if (players != party_players_ || slot != party_slot_)
            for (auto& line : players_) line.clear();
        party_players_ = players;
        party_slot_ = slot;
    }

    void on_player(int slot, const Sample& s, double arrived_ms) {
        Lock hold(lock_);
        players_[slot - FIRST_GUEST_SLOT].push(s, arrived_ms);
    }

    void on_player_restart(int slot) {
        Lock hold(lock_);
        players_[slot - FIRST_GUEST_SLOT].clear();
        events_ += "@" + std::to_string(slot) + " S\n";
    }

    // What the host's game posted, into one guest's box. An empty slot takes no events: whoever comes starts on a new
    // session, which drops them (SureSender::forget).
    void absorb(const Outgoing& in, bool lanes) {
        if (in.reset) reset();
        Lock hold(lock_);
        if (in.have_sample) {
            out_.sample = in.sample;
            out_.have_sample = true;
        }
        if (in.map_changed) {
            out_.map = in.map;
            out_.map_changed = true;
        }
        if (!lanes) return;
        for (const std::string& text : in.sure) keep(out_.sure, text);
        for (const Move& move : in.quick) keep(out_.quick, move.text, move.age_ms);
        for (const std::string& text : in.enemies) keep(out_.enemies, text);
    }

    // The player left (pp_stop): run() ends. Cleared just before a start file is read, so a Leave after that still counts.
    void ask_stop() {
        stop = true;
        SetEvent(wake);
    }

    HANDLE wake = nullptr;
    std::atomic<bool> stop{false};

private:
    class Lock {
    public:
        explicit Lock(SRWLOCK& l) : l_(l) { AcquireSRWLockExclusive(&l_); }
        ~Lock() { ReleaseSRWLockExclusive(&l_); }
    private:
        SRWLOCK& l_;
    };

    void post(std::vector<std::string>& list, std::string text) {
        {
            Lock hold(lock_);
            keep(list, std::move(text));
        }
        SetEvent(wake);
    }

    // Longer than a packet can carry would stop the lane for good. And with no relay thread running, nobody empties these.
    static void keep(std::vector<std::string>& list, std::string text) {
        if (list.size() >= MAX_SURE_PENDING) return;
        if (text.size() > MAX_TEXT) text.resize(MAX_TEXT);
        list.push_back(std::move(text));
    }

    static void keep(std::vector<Move>& list, std::string text, double age_ms) {
        if (list.size() >= MAX_SURE_PENDING) return;
        if (text.size() > MAX_TEXT) text.resize(MAX_TEXT);
        list.push_back({std::move(text), age_ms});
    }

    struct Waiting {
        double arrived_ms, age_ms;     // age_ms: how long ago the partner's game read it, when it arrived
        std::string text;
    };

    SRWLOCK lock_;
    Outgoing out_;
    Timeline timeline_;
    std::string events_, enemies_, status_;
    std::deque<Waiting> quick_;
    std::array<Timeline, MAX_SLOT - HOST_SLOT> players_;    // a party: slots 2 to 6
    int party_players_ = 0, party_slot_ = 0;
};

inline Mailbox mail;

class Writer {
public:
    explicit Writer(std::string& out) : out_(out) {}
    template <typename T> void put(T v) { out_.append(reinterpret_cast<const char*>(&v), sizeof v); }
    void text(std::string_view s) {
        put<uint16_t>(static_cast<uint16_t>(s.size()));
        out_.append(s);
    }

private:
    std::string& out_;
};

class Reader {
public:
    explicit Reader(std::string_view data) : data_(data) {}

    template <typename T> T get() {
        T v{};
        if (data_.size() < sizeof v) {
            ok = false;
            return v;
        }
        std::memcpy(&v, data_.data(), sizeof v);
        data_.remove_prefix(sizeof v);
        return v;
    }

    std::string_view text() {
        const uint16_t n = get<uint16_t>();
        if (!ok || data_.size() < n) {
            ok = false;
            return {};
        }
        std::string_view s = data_.substr(0, n);
        data_.remove_prefix(n);
        return s;
    }

    bool left() const { return ok && !data_.empty(); }
    bool ok = true;

private:
    std::string_view data_;
};

enum Section : uint8_t { SEC_STATE = 1, SEC_SURE = 2, SEC_QUICK = 3, SEC_ENEMY = 4, SEC_HELLO = 5, SEC_PLAYER = 6 };
constexpr uint8_t FLAG_FROM_HOST = 1;

inline void put_sample(Writer& w, const Sample& s) {
    const auto speed = [](float v) { return static_cast<int16_t>(std::isfinite(v) ? std::clamp(v, -32000.0f, 32000.0f) : 0.0f); };
    w.put<uint32_t>(s.ms);
    w.put<float>(s.x);
    w.put<float>(s.y);
    w.put<float>(s.z);
    w.put<float>(s.yaw);
    w.put<int16_t>(speed(s.vx));
    w.put<int16_t>(speed(s.vy));
    w.put<int16_t>(speed(s.vz));
    w.put<float>(s.hp);
    w.put<float>(s.max_hp);
    w.put<uint32_t>(s.map);
    w.put<uint16_t>(s.flags);
}

inline Sample get_sample(Reader& r) {
    Sample s;
    s.ms = r.get<uint32_t>();
    s.x = r.get<float>();
    s.y = r.get<float>();
    s.z = r.get<float>();
    s.yaw = r.get<float>();
    s.vx = r.get<int16_t>();
    s.vy = r.get<int16_t>();
    s.vz = r.get<int16_t>();
    s.hp = r.get<float>();
    s.max_hp = r.get<float>();
    s.map = r.get<uint32_t>();
    s.flags = r.get<uint16_t>();
    return s;
}

constexpr size_t SESSIONS_RETIRED = 8;      // the partner's old sessions: their packets can still be on the way...
constexpr double SESSION_RETIRED_S = 5;     // ...but not after this. One heard later is alive: a corrupt packet took its place

// The sender's clock, always moving on, so a partner can tell a late packet of an older session from a new start (handle).
// Compared around the 32-bit circle, where half of all stamps have the top bit set: with no last session there's nothing to
// be older than. A process's first session must come from the clock, or a restarted partner looks like the same one.
inline uint32_t next_session(uint32_t last, uint64_t wall_ms) {
    uint32_t stamped = static_cast<uint32_t>(wall_ms);
    if (last != 0 && static_cast<int32_t>(stamped - last) <= 0) stamped = last + 1;
    return stamped ? stamped : 1;
}

// The lowest of something over the last 6 s (eight buckets of 0.75 s), as the Timeline keeps the fastest trip: a slower
// route counts once the old lows have aged out.
class RecentLow {
public:
    void clear() {
        lows_.fill(1e18);
        start_ = -1;
    }

    void add(double value, double now_ms) {
        if (start_ < 0 || now_ms - start_ >= BUCKET_MS * BUCKETS) {
            lows_.fill(1e18);
            start_ = now_ms;
        }
        while (now_ms - start_ >= BUCKET_MS) {
            start_ += BUCKET_MS;
            std::rotate(lows_.begin(), lows_.begin() + 1, lows_.end());
            lows_.back() = 1e18;
        }
        lows_.back() = std::min(lows_.back(), value);
    }

    double low() const { return *std::min_element(lows_.begin(), lows_.end()); }
    bool known() const { return low() < 1e17; }

private:
    static constexpr int BUCKETS = 8;
    static constexpr double BUCKET_MS = 750;
    std::array<double, BUCKETS> lows_{1e18, 1e18, 1e18, 1e18, 1e18, 1e18, 1e18, 1e18};
    double start_ = -1;
};

// A host with several guests runs a Relay for each (party.hpp): what a guest says goes here, not into that Relay's Mailbox.
class Hub {
public:
    virtual ~Hub() = default;
    virtual void on_sample(int slot, const Sample& s, double arrived_ms) = 0;
    virtual bool on_sure(int slot, const std::string& text) = 0;      // false: no room, as Mailbox::on_event
    virtual void on_quick(int slot, std::string_view text, double arrived_ms, double age_ms) = 0;
    virtual void on_restart(int slot) = 0;
};

class Relay {
public:
    Relay(std::string role, const std::wstring& dir, std::unique_ptr<Link> link, const std::string* secret,
          const Ini& ini, const std::string& version, std::function<void(const std::string&)> log, Mailbox& box = mail)
        : role_(std::move(role)), link_(std::move(link)), log_(std::move(log)), box_(box), version_(clean_token(version)) {
        status_path = dir + L"\\net_status.txt";
        if (secret) auth_ = std::make_unique<Auth>(*secret, role_);
        for (const auto& [key, value] : ini)
            if (is_shared_setting(key)) settings_[key] = lower(clean_token(value));
        peer_ = link_->peer;
        new_session();
    }

    void tick(double now) {
        receive_all(now);
        flush(now);
    }

    void wait() { link_->wait(TICK, box_.wake); }

    // One packet as it came off the wire, signature and all.
    void on_packet(const Addr& from, const std::string& packet, double now) {
        // Checked before anything else (before a host takes a sender as its partner): with a secret only validly signed
        // packets count; without one, signed packets mean the partner set a secret we don't have.
        if (auth_) {
            auto opened = auth_->open(packet);
            if (!opened) {
                rejected_++;
                return;
            }
            handle(from, *opened, now);
        } else if (packet.compare(0, 4, Auth::MAGIC, 4) == 0) {
            rejected_++;
        } else {
            handle(from, packet, now);
        }
    }

    // Past the signature. Public for the test that sets a packet against unreadable memory, to catch any over-read.
    void handle(const Addr& addr, std::string_view data, double now) {
        // A stranger's old-version packet says nothing about the partner.
        const bool stranger = peer_ && *peer_ != addr && now - last_heard_ <= PEER_TIMEOUT;
        if (!data.empty() && data[0] == '{') {
            if (!stranger) partner_version_ = "1.4.1-or-older";     // protocol 2 was JSON
            return;
        }
        Reader r(data);
        const auto marker = r.get<uint8_t>();
        const auto protocol = r.get<uint8_t>();
        if (!r.ok || marker != MARKER) return;
        if (protocol != PROTOCOL) {
            if (!stranger) partner_version_ = "other-protocol";
            return;
        }
        const auto flags = r.get<uint8_t>();
        const auto session = r.get<uint32_t>();
        const auto their_view = r.get<uint32_t>();
        const auto sequence = r.get<uint16_t>();
        const auto their_ms = r.get<uint32_t>();
        const auto echo = r.get<uint32_t>();
        const auto hold = r.get<uint16_t>();
        const auto ack_next = r.get<uint32_t>();
        const auto ack_bits = r.get<uint32_t>();
        if (!r.ok || session == 0) return;       // no relay uses session 0: it means "partner not known yet"

        const bool from_host = (flags & FLAG_FROM_HOST) != 0;
        bool new_sender = false;
        if (role_ == "host") {
            if (from_host) return;
            if (!peer_ || *peer_ != addr) {
                // Pinned to the first peer: another sender is only taken once the current one went silent.
                if (peer_ && now - last_heard_ <= PEER_TIMEOUT) return;
                peer_ = addr;
                retired_.clear();
                new_sender = true;
                echo_ms_ = 0;           // (the one before's timing: a new guest's first round trips read as garbage)
                rtt_ms_ = -1;
                log_("peer connected: " + logged(addr));
            }
        } else {
            // A guest still looking for its host pins the first host that answers; other guests are ignored.
            if (!from_host) return;
            if (!peer_) {
                peer_ = addr;
                log_("found the host: " + logged(addr));
            } else if (*peer_ != addr) {
                return;
            }
        }
        // Older than the one we're following, and that one is alive: a straggler, even of a session never seen here (two
        // resets close together). Silence is the way out, should the partner's clock have been put back. A sender just taken
        // over isn't on that clock at all, and one that left a made-up session behind mustn't keep the real partner waiting.
        if (!new_sender && peer_session_ != 0 && static_cast<int32_t>(session - peer_session_) < 0 &&
            now - last_heard_ <= SESSION_RETIRED_S)
            return;
        // A packet of the partner's last session, overtaken on the way by its first of the new one. Taken for a restart it
        // would put the lanes back on old numbers, and whatever the partner has confirmed since would count as delivered.
        for (auto it = retired_.begin(); it != retired_.end(); ++it) {
            if (it->first != session) continue;
            if (now - it->second <= SESSION_RETIRED_S) return;
            retired_.erase(it);
            break;
        }
        last_heard_ = now;
        received_++;
        if (session != peer_session_) partner_restarted(session, now);

        const uint16_t expected = static_cast<uint16_t>(last_sequence_ + 1);
        const int16_t gap = static_cast<int16_t>(sequence - expected);
        if (sequence_known_ && gap > 0 && gap < 1000) lost_ += gap;
        if (!sequence_known_ || gap >= 0 || gap < -1000) last_sequence_ = sequence;   // far "behind" is a very long silence
        sequence_known_ = true;

        const double ms = clock_ms();
        echo_ms_ = their_ms;
        echo_arrived_ms_ = ms;
        if (echo) {
            const double rtt = ms - static_cast<double>(echo) - static_cast<double>(hold);
            if (rtt >= 0 && rtt < 5000) {
                rtt_ms_ = rtt_ms_ < 0 ? rtt : rtt_ms_ + (rtt - rtt_ms_) * 0.1;
                shortest_rtt_.add(rtt, ms);
            }
        }
        // This packet's trip on the two clocks, against the fastest lately: how much later than that it came.
        const double trip = ms - static_cast<double>(their_ms);
        fastest_trip_.add(trip, ms);
        const double late = trip - fastest_trip_.low();
        const bool synced = their_view == session_;      // sure and quick numbers only mean something between these two
        if (synced) sure_out_.on_ack(ack_next, ack_bits);

        while (r.left()) {
            const auto section = r.get<uint8_t>();
            if (section == SEC_STATE) {
                Sample s = get_sample(r);
                if (r.ok && sane(s.x) && sane(s.y) && sane(s.z) && sane(s.yaw) && sane(s.hp) && sane(s.max_hp)) {
                    box_.on_sample(s, ms);
                    if (hub_) hub_->on_sample(my_slot_, s, ms);
                }
            } else if (section == SEC_SURE) {
                const auto id = r.get<uint32_t>();
                std::string_view text = r.text();
                if (!r.ok || text.size() > MAX_TEXT) return;
                if (synced) {
                    if (ack_wanted_at_ < 0) ack_wanted_at_ = now;
                    sure_in_.on_event(id, std::string(text), [this](const std::string& t) { return hub_ ? hub_->on_sure(my_slot_, t) : box_.on_event(t); });
                }
            } else if (section == SEC_QUICK) {
                const auto id = r.get<uint32_t>();
                const auto age = r.get<uint16_t>();
                std::string_view text = r.text();
                if (!r.ok || text.size() > MAX_TEXT) return;
                // How long ago the partner's game read the move: held there before this copy went (its age), this packet's
                // lateness, and the trip itself, half the shortest round trip lately. That half is a guess on a route slower
                // one way than the other, which no echo can tell; half the smoothed round trip guessed jitter and loss too.
                const double one_way = shortest_rtt_.known() ? shortest_rtt_.low() / 2 : (rtt_ms_ < 0 ? 0 : rtt_ms_ / 2);
                const double old = age + late + one_way;
                if (synced && quick_in_.fresh(id) && old <= QUICK_REPLAY_MS) {
                    if (hub_) hub_->on_quick(my_slot_, text, ms, old);
                    else box_.on_quick(text, ms, old);
                }
            } else if (section == SEC_ENEMY) {
                std::string_view text = r.text();
                if (!r.ok || text.size() > MAX_TEXT) return;
                box_.on_enemies(text);
            } else if (section == SEC_HELLO) {
                std::string_view text = r.text();
                if (!r.ok) return;
                on_hello(std::string(text));
            } else if (section == SEC_PLAYER) {
                // Another guest, passed on by the host. A host takes this from nobody: a guest speaks for itself.
                const auto slot = r.get<uint8_t>();
                Sample s = get_sample(r);
                if (r.ok && role_ != "host" && slot >= FIRST_GUEST_SLOT && slot <= MAX_SLOT && sane(s.x) && sane(s.y) && sane(s.z) &&
                    sane(s.yaw) && sane(s.hp) && sane(s.max_hp))
                    box_.on_player(slot, s, ms);
            } else {
                return;
            }
        }
    }

    // rejected_elsewhere: a party's other relays', which share this socket.
    std::string status(double now, long long rejected_elsewhere = 0) {
        bool connected = peer_ && now - last_heard_ <= PEER_TIMEOUT;
        std::string peer = "-";
        if (peer_) {
            peer = link_->describe(*peer_);
            std::replace(peer.begin(), peer.end(), ' ', '_');
        }
        char rtt[32] = "-";
        if (rtt_ms_ >= 0) std::snprintf(rtt, sizeof rtt, "%.0f", rtt_ms_);
        std::string mismatch;
        for (const auto& k : mismatch_) mismatch += (mismatch.empty() ? "" : ",") + k;
        if (auth_ && auth_->clock_off > 0 && !connected) mismatch += std::string(mismatch.empty() ? "" : ",") + "clock";
        const long long got = received_ - received_mark_, lost = lost_ - lost_mark_;
        const double loss = got + lost > 0 ? 100.0 * lost / static_cast<double>(got + lost) : 0;
        received_mark_ = received_;
        lost_mark_ = lost_;
        double jitter = 0, delay = 0;
        box_.link_numbers(jitter, delay);
        char quality[128];
        std::snprintf(quality, sizeof quality, " jitter_ms=%.1f delay_ms=%.1f loss_pct=%.1f resent=%lld resent_early=%lld pending=%zu",
                      jitter, delay, loss, sure_out_.resent, sure_out_.resent_early, sure_out_.pending());
        const Link::Route route = peer_ ? link_->route(*peer_) : Link::Route{};
        const std::string problem = link_->problem();
        // time= (wall clock) lets the mod tell a running relay from a stale status file before starting another.
        return "role=" + role_ + " via=" + link_->via() + " connected=" + (connected ? "yes" : "no") + " peer=" + peer +
               " rtt_ms=" + rtt + " route=" + route.kind +
               " route_ping_ms=" + (route.ping_ms < 0 ? "-" : std::to_string(route.ping_ms)) +
               " sent=" + std::to_string(sent_) + " received=" + std::to_string(received_) +
               " filtered=" + std::to_string(link_->filtered) + " rejected=" + std::to_string(rejected_ + rejected_elsewhere) +
               " auth=" + (auth_ ? "on" : "off") + " version=" + version_ +
               " partner_version=" + (partner_version_.empty() ? "-" : partner_version_) +
               " partner_map=" + (partner_map_.empty() ? "-" : partner_map_) +
               " mismatch=" + (mismatch.empty() ? "-" : mismatch) + " events_acked=" + std::to_string(sure_out_.acked) +
               " events_in=" + std::to_string(sure_in_.count) + quality +
               " link_problem=" + (problem.empty() ? "-" : problem) + " refused=" + std::to_string(link_->refused) +
               " time=" + std::to_string(static_cast<long long>(std::time(nullptr))) +
               (party_players_ ? " players=" + std::to_string(party_players_) + " slot=" + std::to_string(party_slot_) : "");
    }

    std::string describe_self() { return link_->describe_self(); }

    std::wstring status_path;

    // One of a party's relays (party.hpp): what its guest says goes to hub, and its hello says who's who.
    void join_party(Hub* hub, int slot, int players) {
        hub_ = hub;
        my_slot_ = slot;
        hello_extra_ = "players=" + std::to_string(players) + "\nslot=" + std::to_string(slot) + "\n";
    }

    // Where another guest is, for this one: newest wins.
    void queue_player(int slot, const Sample& s) {
        players_out_[slot - FIRST_GUEST_SLOT] = s;
        players_waiting_ = true;
    }

    bool has_partner() const { return peer_.has_value(); }
    bool partner_is(const Addr& a) const { return peer_ && *peer_ == a; }
    bool here(double now) const { return peer_ && now - last_heard_ <= PEER_TIMEOUT; }
    bool heard_of_someone() const { return !partner_version_.empty(); }
    long long rejected() const { return rejected_; }
    const std::string& partner_version() const { return partner_version_; }
    const std::string& partner_map() const { return partner_map_; }
    const std::vector<std::string>& mismatch() const { return mismatch_; }

private:
    void new_session() {
        static uint32_t last = 0;
        last = next_session(last, static_cast<uint64_t>(wall_seconds() * 1000));
        session_ = last;
        sure_out_ = SureSender();
        quick_out_.restart();
        enemy_out_.clear();
        sure_in_.restart();
        quick_in_.restart();
        sequence_known_ = false;
    }

    void start_packet(std::string& p) {
        const double ms = clock_ms();
        p.clear();
        Writer w(p);
        w.put<uint8_t>(MARKER);
        w.put<uint8_t>(PROTOCOL);
        w.put<uint8_t>(role_ == "host" ? FLAG_FROM_HOST : 0);
        w.put<uint32_t>(session_);
        w.put<uint32_t>(peer_session_);
        w.put<uint16_t>(sequence_);
        w.put<uint32_t>(static_cast<uint32_t>(ms));
        w.put<uint32_t>(echo_ms_);
        w.put<uint16_t>(static_cast<uint16_t>(std::min(65000.0, echo_ms_ ? ms - echo_arrived_ms_ : 0.0)));
        w.put<uint32_t>(sure_in_.next());
        w.put<uint32_t>(sure_in_.bits());
        header_bytes_ = p.size();
    }

    void send_packet(const std::string& p, double now, const Addr* to = nullptr) {
        const Addr* target = to ? to : (peer_ ? &*peer_ : nullptr);
        if (!target) return;
        link_->send(*target, auth_ ? auth_->seal(p) : p);
        sent_++;
        sequence_++;
        last_send_ = now;
        ack_wanted_at_ = -1;
    }

    double retry_s() const {
        return rtt_ms_ < 0 ? 0.2 : std::clamp(rtt_ms_ * 0.0015 + 0.015, RETRY_MIN, RETRY_MAX);
    }

    // A sure event the partner's acknowledgement passed over goes again this long after it was sent (SureSender): by then
    // its own confirmation would have come, even with a packet overtaken on the way by an eighth of a round trip.
    double lost_after_s() const {
        return rtt_ms_ < 0 ? retry_s() : std::clamp(std::max(rtt_ms_ * 1.125, rtt_ms_ + 10) / 1000, RETRY_MIN, RETRY_MAX);
    }

    std::string hello_text() const {
        std::string text = version_ + "\n" + map_name_.substr(0, 64) + "\n";
        for (const auto& [key, value] : settings_) text += key + "=" + value + "\n";
        return text + hello_extra_;
    }

    void flush(double now) {
        Mailbox::Outgoing out;
        box_.take_outgoing(out);
        if (out.reset) new_session();
        // Held events the game had no room for: tried again here too, for a partner with nothing new to send (lanes.hpp).
        sure_in_.drain([this](const std::string& t) { return hub_ ? hub_->on_sure(my_slot_, t) : box_.on_event(t); });
        if (out.map_changed) {
            map_name_ = std::move(out.map);
            hello_due_ = true;
        }
        for (auto& text : out.sure) sure_out_.push(std::move(text));
        for (auto& move : out.quick) quick_out_.push(std::move(move.text), now - move.age_ms / 1000);
        for (auto& text : out.enemies) enemy_out_.push_back(std::move(text));
        while (enemy_out_.size() > MAX_ENEMY_LINES) enemy_out_.pop_front();
        quick_out_.expire(now);

        const bool partner_here = now - last_heard_ <= PEER_TIMEOUT;
        // Sure events were lost for good while the partner was away, and numbers can't bridge a hole: a new session makes
        // it hear S, this side hears S too, and each tells the other again what it needs to know.
        if (sure_out_.overflowed && peer_session_ != 0 && partner_here) {
            new_session();
            tell_restart();
        }

        if (!peer_) {
            if (role_ != "host" && now - last_probe_ >= PROBE_EVERY) {
                last_probe_ = now;
                std::string p;
                start_packet(p);
                for (const Addr& friend_id : link_->candidates()) send_packet(p, now, &friend_id);
            }
            return;
        }
        if (now - last_hello_ >= HELLO_EVERY) hello_due_ = true;

        std::string p;
        start_packet(p);
        int packets = 1;
        // Room for n more bytes, starting another packet if this one is full. False once this round's limit is reached.
        auto room = [&](size_t n) {
            if (p.size() + n <= MAX_PACKET) return true;
            if (packets == MAX_PACKETS_AT_ONCE) return false;
            packets++;
            send_packet(p, now);
            start_packet(p);
            return true;
        };
        Writer w(p);
        // Nobody heard for PEER_TIMEOUT (left, loading, or a link gap): only the hello and the keepalive go out. Sure events
        // wait in their queue as they always did; where this player is, quick events and enemy lines are for now, and were
        // sent to an empty address for good after a guest left a party, a packet a frame for every slot so left.
        if (out.have_sample && partner_here) {
            w.put<uint8_t>(SEC_STATE);
            put_sample(w, out.sample);
        }
        if (hello_due_) {
            hello_due_ = false;
            last_hello_ = now;
            w.put<uint8_t>(SEC_HELLO);
            w.text(hello_text());
        }
        // Sure lane first: it's what must not wait behind anything. With nobody answering they wait here, not on the wire:
        // a long queue resent forever at an empty address is megabytes a second.
        if (peer_session_ != 0 && partner_here) {
            sure_out_.for_each_due(now, retry_s(), [&](const SureSender::Item& item) {
                if (!room(1 + 4 + 2 + item.text.size())) return false;
                w.put<uint8_t>(SEC_SURE);
                w.put<uint32_t>(item.id);
                w.text(item.text);
                return true;
            }, lost_after_s());
        }
        if (partner_here) quick_out_.for_each(now, QUICK_GAP, [&](const QuickSender::Item& item, double age) {
            if (!room(1 + 4 + 2 + 2 + item.text.size())) return false;
            w.put<uint8_t>(SEC_QUICK);
            w.put<uint32_t>(item.id);
            w.put<uint16_t>(static_cast<uint16_t>(age * 1000));
            w.text(item.text);
            return true;
        });
        if (!partner_here) enemy_out_.clear();
        while (!enemy_out_.empty() && room(1 + 2 + enemy_out_.front().size())) {
            w.put<uint8_t>(SEC_ENEMY);
            w.text(enemy_out_.front());
            enemy_out_.pop_front();
        }
        if (players_waiting_ && partner_here && now - last_players_ >= PLAYERS_EVERY) {
            last_players_ = now;
            players_waiting_ = false;
            for (size_t i = 0; i < players_out_.size(); i++) {
                if (!players_out_[i]) continue;
                if (!room(1 + 1 + SAMPLE_BYTES)) {
                    players_waiting_ = true;
                    break;
                }
                w.put<uint8_t>(SEC_PLAYER);
                w.put<uint8_t>(static_cast<uint8_t>(FIRST_GUEST_SLOT + i));
                put_sample(w, *players_out_[i]);
                players_out_[i].reset();
            }
        }
        const bool ack_late = ack_wanted_at_ >= 0 && now - ack_wanted_at_ >= ACK_WAIT;
        if (p.size() > header_bytes_ || ack_late || now - last_send_ >= KEEPALIVE_EVERY) send_packet(p, now);
    }

    void receive_all(double now) {
        for (auto& [addr, packet] : link_->receive()) on_packet(addr, packet, now);
    }

    // The other side started, or turned sync on again: nothing either of us numbered before means anything now.
    void partner_restarted(uint32_t session, double now) {
        if (peer_session_ != 0) retired_.emplace_back(peer_session_, now);
        if (retired_.size() > SESSIONS_RETIRED) retired_.erase(retired_.begin());
        peer_session_ = session;
        sure_in_.restart();
        quick_in_.restart();
        sure_out_.forget();
        sequence_known_ = false;
        fastest_trip_.clear();      // maybe another process, on a clock of its own, or another partner on another route
        shortest_rtt_.clear();
        tell_restart();
        hello_due_ = true;
    }

    void tell_restart() {
        if (hub_) {
            box_.forget_partner();
            hub_->on_restart(my_slot_);
        } else {
            box_.on_partner_restart();
        }
    }

    // Past this a float stops being a place or a health bar, and sums on it stop being finite.
    static bool sane(float v) { return std::isfinite(v) && std::fabs(v) < 1e9f; }

    void on_hello(const std::string& text) {
        std::vector<std::string> lines;
        for (size_t at = 0; at < text.size();) {
            size_t end = text.find('\n', at);
            if (end == std::string::npos) end = text.size();
            lines.push_back(text.substr(at, end - at));
            at = end + 1;
        }
        if (lines.size() < 2) return;
        partner_version_ = clean_token(lines[0]);
        partner_map_ = clean_token(lines[1], 64);
        mismatch_.clear();
        long players = 0, slot = 0;     // a host with more than two players says so, and who this guest is (party.hpp)
        for (size_t i = 2; i < lines.size(); i++) {
            size_t eq = lines[i].find('=');
            if (eq == std::string::npos) continue;
            const std::string key = lines[i].substr(0, eq);
            if (key == "players") players = std::strtol(lines[i].c_str() + eq + 1, nullptr, 10);
            else if (key == "slot") slot = std::strtol(lines[i].c_str() + eq + 1, nullptr, 10);
            auto mine = settings_.find(key);
            // Both values went through the same cleaning, or "1 000" would differ from itself on the two PCs.
            if (mine != settings_.end() && lower(clean_token(lines[i].substr(eq + 1))) != mine->second)
                mismatch_.push_back(mine->first);
        }
        if (role_ != "host") {
            const bool party = players > 2 && players <= MAX_SLOT && slot >= FIRST_GUEST_SLOT && slot <= players;
            party_players_ = party ? static_cast<int>(players) : 0;
            party_slot_ = party ? static_cast<int>(slot) : 0;
            box_.set_party(party_players_, party_slot_);
        }
    }

    // Who, for relay_log.txt: never a Steam friend's name (players attach the log to bug reports), an address otherwise.
    std::string logged(const Addr& a) { return a.steam ? std::string("a Steam friend") : link_->describe(a); }

    std::string role_;
    std::unique_ptr<Link> link_;
    std::function<void(const std::string&)> log_;
    Mailbox& box_;
    std::unique_ptr<Auth> auth_;
    std::map<std::string, std::string> settings_;
    std::string version_, partner_version_, partner_map_, map_name_;
    std::vector<std::string> mismatch_;
    std::optional<Addr> peer_;     // host: learned from the first packet; Steam guest: maybe found later
    uint32_t session_ = 0, peer_session_ = 0;
    std::vector<std::pair<uint32_t, double>> retired_;   // oldest first: session, when it was replaced
    SureSender sure_out_;
    SureReceiver sure_in_;
    QuickSender quick_out_;
    QuickReceiver quick_in_;
    std::deque<std::string> enemy_out_;
    uint16_t sequence_ = 0, last_sequence_ = 0;
    bool sequence_known_ = false, hello_due_ = true;
    uint32_t echo_ms_ = 0;
    double echo_arrived_ms_ = 0, rtt_ms_ = -1;
    RecentLow fastest_trip_, shortest_rtt_;     // the partner's packets, for how old a quick event is
    size_t header_bytes_ = 0;
    double last_send_ = 0, last_heard_ = 0, last_hello_ = 0, last_probe_ = -1e9, ack_wanted_at_ = -1;
    long long rejected_ = 0, received_ = 0, sent_ = 0, lost_ = 0, received_mark_ = 0, lost_mark_ = 0;
    // A party. As a host's relay for one guest:
    static constexpr size_t SAMPLE_BYTES = 40;
    Hub* hub_ = nullptr;
    int my_slot_ = 0;
    std::string hello_extra_;
    std::array<std::optional<Sample>, MAX_SLOT - HOST_SLOT> players_out_;
    bool players_waiting_ = false;
    double last_players_ = 0;
    // As a guest: what the host's hello said.
    int party_players_ = 0, party_slot_ = 0;
};

}  // namespace relay

#include "party.hpp"

namespace relay {

struct Options {
    std::string role;              // "host" or "client"
    std::wstring dir;              // the mod's files
    std::string peer;              // client: the host's address; Steam: a name or id, or nothing
    std::string transport = "udp";
    bool allow_any = false;
    bool this_pc_only = false;     // tests: two copies on one PC, nothing for Windows' firewall to ask about
    std::wstring ini;
    std::string version = "?";
    int port = 47800;
    double seconds = 0;            // 0 = for the life of the game
};

std::unique_ptr<Link> make_steam_link(const std::string& role, const std::string& peer);

// Runs until the player leaves (Mailbox::ask_stop), at most for the life of the game: it lives in the game's own process,
// so it can't outlive it. A failure leaves relay_error.txt next to the status, since nobody watches a console inside the game.
inline void run(Options o, const std::function<void(const std::string&)>& log) {
    const std::wstring status_path = o.dir + L"\\net_status.txt";
    timeBeginPeriod(1);    // Windows sleeps in ~15.6 ms steps by default, too coarse for TICK
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);   // every core may be busy with the game
    std::string failure;
    try {
        Ini ini = o.ini.empty() ? Ini{} : read_ini(o.ini);
        auto any = ini.find("allowanyaddress");
        if (any != ini.end()) {
            std::string v = lower(any->second);
            // A virtual LAN with unusual addresses (UU Accelerator's multiplayer, ZeroTier...): the player opened it.
            if (v == "on" || v == "yes" || v == "true" || v == "1") o.allow_any = true;
        }
        if (lower(ini["thispconly"]) == "on") o.this_pc_only = true;
        std::string secret;
        if (auto it = ini.find("secret"); it != ini.end()) secret = it->second;
        std::string secret_lower = lower(secret);
        bool signed_packets = !(secret_lower.rfind("put-", 0) == 0 || secret_lower.empty() || secret_lower == "off" ||
                                secret_lower == "none");
        std::unique_ptr<Link> link;
        if (o.transport == "steam") link = make_steam_link(o.role, o.peer);
        else link = std::make_unique<UdpLink>(o.role, o.peer, o.port, o.allow_any, o.this_pc_only);
        const auto serve = [&](auto& relay) {
            log("PBZCoop relay " + o.role + " on " + relay.describe_self() + (signed_packets ? ", packets signed (Secret set)" : ""));
            const double start = monotonic();
            double last_status = 0;
            while (!mail.stop) {
                double now = monotonic();
                relay.tick(now);
                if (now - last_status >= 1.0) {
                    std::string line = relay.status(now);
                    mail.set_status(line);
                    write_atomic(status_path, line + "\n");
                    log(line);
                    last_status = now;
                }
                if (o.seconds > 0 && now - start >= o.seconds) break;
                relay.wait();
            }
        };
        // The host's setting decides: a guest follows what the host's hello says, whatever its own ini has.
        if (o.role == "host" && party_size(ini) > 2) {
            Party party(o.dir, std::move(link), signed_packets ? &secret : nullptr, ini, o.version, log);
            serve(party);
        } else {
            Relay relay(o.role, o.dir, std::move(link), signed_packets ? &secret : nullptr, ini, o.version, log);
            serve(relay);
        }
    } catch (const std::exception& e) {
        failure = e.what();
        write_atomic(o.dir + L"\\relay_error.txt", failure + "\n");
        log("relay failed: " + failure);
    }
    timeEndPeriod(1);
    // error= comes last and may hold spaces: status.lua shows it to the player.
    const std::string stopped = "role=" + o.role + " connected=no stopped=yes" + (failure.empty() ? "" : " error=" + failure);
    write_atomic(status_path, stopped + "\n");
    if (o.seconds > 0) return;     // a timed run (the tests): its caller still reads the last status
    // The socket is closed (relay and link ended with the try) and this thread goes back to waiting for a start file:
    // nothing of this run may reach the next one, which can be another role.
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_NORMAL);
    mail.reset();
    mail.set_party(0, 0);
    mail.set_status(stopped);
}

}  // namespace relay
