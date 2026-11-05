// Steam P2P for the relay: Steam Networking Messages through the game's own steam_api64.dll. This runs inside the game:
// Steam is already started, so nothing here may init it, shut it down or take over callback dispatch. Only session requests
// need a callback, and they arrive on whatever thread the game runs Steam callbacks on, so they're queued for the
// relay thread.
//
// Everything sent is unreliable and leaves at once: the lanes in lanes.hpp do what reliability is needed, as on UDP.
// Calls the link can live without are looked up with find_optional: a Steam that lacks them still links, only slower.
#include "relay.hpp"

#include <cstddef>
#include <mutex>

namespace {

constexpr uint32_t APP_ID = 4115450;
constexpr int CHANNEL = 0;
constexpr int SEND_NO_NAGLE = 1;
constexpr int SEND_AUTO_RESTART_BROKEN_SESSION = 32;
constexpr int FRIEND_FLAG_IMMEDIATE = 4;       // regular Steam friends
constexpr int IDENTITY_TYPE_STEAMID = 16;
constexpr int CALLBACK_SESSION_REQUEST = 1251; // SteamNetworkingMessagesSessionRequest_t
constexpr int CONFIG_SEND_RATE_MIN = 10;       // ESteamNetworkingConfigValue
constexpr int CONFIG_SEND_RATE_MAX = 11;
constexpr int CONFIG_ICE_ENABLE = 104;         // P2P_Transport_ICE_Enable: what may be tried for a direct route
constexpr int CONFIG_RELAY_PENALTY = 106;      // P2P_Transport_SDR_Penalty: added to a relay's score, which is its ping
constexpr int ICE_STEAM_DECIDES = -1;          // k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_*
constexpr int ICE_PRIVATE = 2, ICE_PUBLIC = 4;
constexpr int STATE_CONNECTING = 1, STATE_FINDING_ROUTE = 2, STATE_CONNECTED = 3;   // ESteamNetworkingConnectionState
constexpr int RESULT_OK = 1;                   // k_EResultOK
constexpr int INFO_FLAG_RELAYED = 16;          // k_nSteamNetworkConnectionInfoFlags_Relayed
constexpr int SEND_RATE = 4 * 1024 * 1024;     // bytes a second, see tune
constexpr int RELAY_PENALTY_MS = 20;
constexpr double CONNECTING_SEND_GAP = 0.25;
constexpr double ACCEPT_SWEEP_EVERY = 1.0;
constexpr double FRIENDS_REFRESH = 5.0;
constexpr int STEAM_WAIT_S = 20;

// Up to 1200 bytes go in one datagram (MTU_DataSize), Steam's own header of 5 included. A longer unreliable message is
// split, and one lost piece loses all of it; past 16500 bytes Steam makes it reliable. A signed packet never gets there.
static_assert(relay::MAX_PACKET + relay::Auth::HEADER + relay::Auth::TAG + 5 <= 1200);

// SteamNetworkingIdentity: a type tag, a size and a 128-byte union (the SteamID64 sits at its start).
struct Identity {
    int32_t type;
    int32_t size;
    uint64_t steam_id;
    uint8_t rest[120];
};
static_assert(sizeof(Identity) == 136);

// The leading fields of SteamNetworkingMessage_t (it is released through the API, never freed here).
struct Message {
    void* data;
    int32_t size;
    uint32_t conn;
    Identity peer;
};

// SteamNetConnectionInfo_t.
struct SessionInfo {
    Identity remote;
    int64_t user_data;
    uint32_t listen_socket;
    uint8_t address[18];
    uint16_t pad;
    uint32_t pop_remote;
    uint32_t pop_relay;        // the relay this side reaches the partner through, 0 if none
    int32_t state;
    int32_t end_reason;
    char end_debug[128];
    char description[128];
    int32_t flags;
    uint32_t reserved[63];
};
static_assert(sizeof(SessionInfo) == 696 && offsetof(SessionInfo, pop_relay) == 172 && offsetof(SessionInfo, flags) == 440);

// SteamNetConnectionRealTimeStatus_t.
struct SessionStatus {
    int32_t state;
    int32_t ping_ms;
    float quality_local, quality_remote;
    float packets_out, bytes_out, packets_in, bytes_in;
    int32_t send_rate;
    int32_t pending_unreliable, pending_reliable, unacked_reliable;
    int64_t queue_time_us;
    uint32_t reserved[16];
};
static_assert(sizeof(SessionStatus) == 120);

struct FriendGameInfo {
    uint64_t game_id;
    uint32_t ip;
    uint16_t port;
    uint16_t query_port;
    uint64_t lobby;
};

// Same declarations, in the same order, as CCallbackBase in Steam's headers: the compiler lays out the vtable from
// them, and Steam calls into it.
class CCallbackBase {
public:
    CCallbackBase() : flags_(0), id_(0) {}
    virtual void Run(void* param) = 0;
    virtual void Run(void* param, bool io_failure, uint64_t call) = 0;
    virtual int GetCallbackSizeBytes() = 0;

protected:
    uint8_t flags_;
    int id_;
};

std::mutex requests_lock;
std::vector<Identity> requests;

class SessionRequestCallback : public CCallbackBase {
public:
    void Run(void* param) override {
        if (!param) return;
        std::lock_guard<std::mutex> lock(requests_lock);
        if (requests.size() < 64) requests.push_back(*static_cast<Identity*>(param));
    }
    void Run(void* param, bool, uint64_t) override { Run(param); }
    int GetCallbackSizeBytes() override { return static_cast<int>(sizeof(Identity)); }
};

SessionRequestCallback session_request_callback;   // registered once, for the life of the game
bool callback_registered = false;

template <typename F>
F find_fn(HMODULE dll, const char* name) {
    auto f = reinterpret_cast<F>(GetProcAddress(dll, name));
    if (!f) throw std::runtime_error(std::string("this game's Steam has no ") + name);
    return f;
}

// What the link can do without: null if this game's Steam doesn't have it.
template <typename F>
F find_optional(HMODULE dll, const char* name) {
    return reinterpret_cast<F>(GetProcAddress(dll, name));
}

// SteamDirect in PhantomPact.ini, off unless it says on: it shows this PC's IP to the partner, so that stays the player's
// choice, and a Steam setting of Never mustn't be overruled by default. run() reads the file but doesn't pass it this far,
// so it's found
// the way main_dll.cpp finds it: this DLL is in <mod>\dlls, and copy N of the game on one PC uses <mod>\instN.
bool direct_wanted() {
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&direct_wanted), &self))
        return false;
    wchar_t path[MAX_PATH * 4];
    std::wstring dir(path, GetModuleFileNameW(self, path, static_cast<DWORD>(std::size(path))));
    for (int up = 0; up < 2; up++) dir = dir.substr(0, dir.find_last_of(L'\\'));
    wchar_t instance[16];
    const DWORD got = GetEnvironmentVariableW(L"PBZCOOP_INSTANCE", instance, 16);     // (16 or more: not written whole)
    if (got > 0 && got < 16 && _wtoi(instance) > 1)
        dir += L"\\inst" + std::wstring(instance);
    relay::Ini ini = relay::read_ini(dir + L"\\PhantomPact.ini");
    return relay::lower(ini["steamdirect"]) == "on";
}

// Settings for all Steam networking in this process, which is only this link. Steam may refuse any of them: each is a
// preference, and the link works without it. They reach sessions opened after this, and it runs before there are any.
void tune(HMODULE dll, void* utils) {
    auto set = find_optional<bool (*)(void*, int, int32_t)>(dll,
                                                            "SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32");
    if (!set) return;
    // Steam paces each session at a fixed 256 KB/s, with one packet of burst, so of six full packets sent at once the last
    // left 23 ms after the first. A UDP socket has no such wait. Traffic is far below either rate: this only shortens
    // bursts. Minimum and maximum equal: that's how Steam's header says to set a rate.
    set(utils, CONFIG_SEND_RATE_MIN, SEND_RATE);
    set(utils, CONFIG_SEND_RATE_MAX, SEND_RATE);
    // Left alone, Steam Networking's player setting decides, and on its usual Default that means Valve's relays unless
    // the ping looks excessive: the extra delay players see next to Tailscale. Asking for direct here passes over that
    // setting, so a partner can see this PC's IP: only with SteamDirect = On. Only friends get a session.
    // A direct route pays 10 ms and 10% in Steam's scoring, and takes over from a working route only if 10% better. With
    // this penalty a tie goes direct when the route is picked, and a direct route 10% quicker replaces the relay later.
    const bool direct = direct_wanted();
    set(utils, CONFIG_ICE_ENABLE, direct ? ICE_PRIVATE | ICE_PUBLIC : ICE_STEAM_DECIDES);
    set(utils, CONFIG_RELAY_PENALTY, direct ? RELAY_PENALTY_MS : 0);
}

class SteamLink : public relay::Link {
public:
    SteamLink(const std::string& role, const std::string& peer_text) {
        HMODULE dll = GetModuleHandleW(L"steam_api64.dll");
        if (!dll) throw std::runtime_error("Steam isn't loaded in this game (steam_api64.dll)");
        auto get_friends = find_fn<void* (*)()>(dll, "SteamAPI_SteamFriends_v018");
        auto get_utils = find_fn<void* (*)()>(dll, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
        auto get_msgs = find_fn<void* (*)()>(dll, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
        // The mod can get here before the game has signed in to Steam.
        for (int i = 0; i < STEAM_WAIT_S * 4 && !(friends_ && msgs_); i++) {
            friends_ = get_friends();
            msgs_ = get_msgs();
            if (!(friends_ && msgs_)) Sleep(250);
        }
        if (!friends_ || !msgs_) throw std::runtime_error("Steam isn't ready: is it running and logged in?");

        persona_ = find_fn<const char* (*)(void*)>(dll, "SteamAPI_ISteamFriends_GetPersonaName");
        friend_count_ = find_fn<int (*)(void*, int)>(dll, "SteamAPI_ISteamFriends_GetFriendCount");
        friend_by_index_ = find_fn<uint64_t (*)(void*, int, int)>(dll, "SteamAPI_ISteamFriends_GetFriendByIndex");
        friend_game_ = find_fn<bool (*)(void*, uint64_t, FriendGameInfo*)>(dll, "SteamAPI_ISteamFriends_GetFriendGamePlayed");
        friend_name_ = find_fn<const char* (*)(void*, uint64_t)>(dll, "SteamAPI_ISteamFriends_GetFriendPersonaName");
        send_ = find_fn<int (*)(void*, const Identity*, const void*, uint32_t, int, int)>(
            dll, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
        receive_ = find_fn<int (*)(void*, int, Message**, int)>(dll, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
        accept_ = find_fn<bool (*)(void*, const Identity*)>(dll, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser");
        release_ = find_fn<void (*)(Message*)>(dll, "SteamAPI_SteamNetworkingMessage_t_Release");
        session_info_ = find_optional<int (*)(void*, const Identity*, SessionInfo*, SessionStatus*)>(
            dll, "SteamAPI_ISteamNetworkingMessages_GetSessionConnectionInfo");
        close_ = find_optional<bool (*)(void*, const Identity*)>(
            dll, "SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser");

        void* utils = get_utils();
        if (utils) {
            tune(dll, utils);
            find_fn<void (*)(void*)>(dll, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess")(utils);
        }
        if (!callback_registered) {
            find_fn<void (*)(CCallbackBase*, int)>(dll, "SteamAPI_RegisterCallback")(&session_request_callback,
                                                                                     CALLBACK_SESSION_REQUEST);
            callback_registered = true;
        }
        if (role != "host" && !peer_text.empty()) {
            bool is_id = peer_text.size() == 17 &&
                         std::all_of(peer_text.begin(), peer_text.end(), [](char c) { return c >= '0' && c <= '9'; });
            if (is_id) {
                relay::Addr a;
                a.steam = std::strtoull(peer_text.c_str(), nullptr, 10);
                peer = a;
            } else {
                wanted_ = relay::lower(relay::strip(peer_text));    // a friend name, case-insensitive
            }
        }
    }

    // Leaving: nothing of this run may reach the next one. Closing also drops whatever the partner sent since the last
    // receive, and it's better than leaving them sending into a queue nobody reads.
    ~SteamLink() override {
        if (!close_) return;
        for (const auto& session : sessions_) {
            Identity id = identity(session.first);
            close_(msgs_, &id);
        }
    }

    void send(const relay::Addr& to, const std::string& data) override {
        Identity id = identity(to.steam);
        double& queued_at = sessions_[to.steam];
        // Before a session is up Steam makes every message reliable, whatever the flags, keeps it and delivers the lot
        // once it's up: seconds of old positions and attacks at 60 a second, ahead of anything new. Just enough goes out
        // to start the session and keep it trying (a reliable message survives the wait, so the first isn't lost).
        if (session_info_) {
            const int state = session_info_(msgs_, &id, nullptr, nullptr);
            if (state == STATE_CONNECTING || state == STATE_FINDING_ROUTE) {
                const double now = relay::monotonic();
                if (now - queued_at < CONNECTING_SEND_GAP) return;
                queued_at = now;
            } else if (state != STATE_CONNECTED) {
                note_end(id);
            }
        }
        // The restart flag: a session that broke (a stall of 10 s, the partner's game restarting) just starts again, which
        // only unreliable traffic can afford. A full send buffer drops the message, like a full socket.
        const int result = send_(msgs_, &id, data.data(), static_cast<uint32_t>(data.size()),
                                 SEND_NO_NAGLE | SEND_AUTO_RESTART_BROKEN_SESSION, CHANNEL);
        if (result != RESULT_OK) refused++;
    }

    std::vector<std::pair<relay::Addr, std::string>> receive() override {
        accept_friends();
        std::vector<std::pair<relay::Addr, std::string>> out;
        Message* batch[32];
        while (true) {
            int n = receive_(msgs_, CHANNEL, batch, 32);
            for (int i = 0; i < n; i++) {
                relay::Addr a;
                a.steam = batch[i]->peer.steam_id;
                sessions_.try_emplace(a.steam, 0.0);
                out.emplace_back(a, std::string(static_cast<const char*>(batch[i]->data), batch[i]->size));
                release_(batch[i]);
            }
            if (n > 0) heard_at_ = relay::monotonic();
            if (n < 32) return out;
        }
    }

    Route route(const relay::Addr& to) override {
        Route r;
        if (!session_info_) return r;
        Identity id = identity(to.steam);
        SessionInfo info{};
        SessionStatus quick{};
        // Any other state means the structs are empty or describe the last session.
        if (session_info_(msgs_, &id, &info, &quick) != STATE_CONNECTED) return r;
        r.kind = (info.flags & INFO_FLAG_RELAYED) || info.pop_relay ? "relay" : "direct";
        r.ping_ms = quick.ping_ms;
        return r;
    }

    void wait(double, HANDLE wake) override {
        // Steam has no socket to wait on: it's polled every millisecond, or sooner when the game has something to send.
        WaitForSingleObject(wake, 1);
    }

    std::vector<relay::Addr> candidates() override {
        double now = relay::monotonic();
        if (now - friends_at_ >= FRIENDS_REFRESH) {
            friends_at_ = now;
            playing_.clear();
            int count = friend_count_(friends_, FRIEND_FLAG_IMMEDIATE);
            for (int i = 0; i < count; i++) {
                uint64_t id = friend_by_index_(friends_, i, FRIEND_FLAG_IMMEDIATE);
                FriendGameInfo info{};
                if (!friend_game_(friends_, id, &info) || (info.game_id & 0xFFFFFF) != APP_ID) continue;
                if (!wanted_.empty() && relay::lower(relay::strip(name_of(id))) != wanted_) continue;
                relay::Addr a;
                a.steam = id;
                playing_.push_back(a);
            }
        }
        return playing_;
    }

    std::string problem() override { return problem_; }

    std::string describe(const relay::Addr& a) override {
        std::string name = name_of(a.steam);
        return name.empty() ? std::to_string(a.steam) : name;
    }

    std::string describe_self() override { return std::string("Steam as ") + persona_(friends_); }

    const char* via() override { return "steam"; }

private:
    static Identity identity(uint64_t steam_id) {
        Identity id{};
        id.type = IDENTITY_TYPE_STEAMID;
        id.size = 8;
        id.steam_id = steam_id;
        return id;
    }

    // Why the last session ended, in Steam's words: nothing else tells why two PCs never connect.
    void note_end(const Identity& id) {
        SessionInfo info{};
        session_info_(msgs_, &id, &info, nullptr);
        if (info.end_reason == 0) return;
        info.end_debug[sizeof info.end_debug - 1] = 0;
        problem_ = std::to_string(info.end_reason) + "_" + info.end_debug;
        for (char& c : problem_)
            if (static_cast<unsigned char>(c) <= ' ' || static_cast<unsigned char>(c) >= 127) c = '_';
    }

    std::string name_of(uint64_t id) {
        const char* name = friend_name_(friends_, id);
        return name ? name : "";
    }

    bool is_friend(uint64_t id) {
        int count = friend_count_(friends_, FRIEND_FLAG_IMMEDIATE);
        for (int i = 0; i < count; i++)
            if (friend_by_index_(friends_, i, FRIEND_FLAG_IMMEDIATE) == id) return true;
        return false;
    }

    void accept(const Identity& id) {
        sessions_.try_emplace(id.steam_id, 0.0);
        accept_(msgs_, &id);
    }

    // Strangers are ignored, so their messages are dropped. Steam posts a request once per attempt: one that came before
    // the callback was registered, or that the game's callbacks held up (a long load), would only come back when the
    // partner's attempt timed out 10 s later. So while nobody is heard, friends in this game are accepted without one.
    // That costs nothing: with no session waiting Steam says no, and the callback isn't the only way in any more.
    void accept_friends() {
        std::vector<Identity> pending;
        {
            std::lock_guard<std::mutex> lock(requests_lock);
            pending.swap(requests);
        }
        for (const Identity& id : pending)
            if (is_friend(id.steam_id)) accept(id);
        const double now = relay::monotonic();
        // (On a timer alone, whoever's talking: with one guest's packets coming all the time, a later guest whose request
        // the callback missed waited on Steam's retries, and in a long load for good.)
        if (now - swept_at_ < ACCEPT_SWEEP_EVERY) return;
        swept_at_ = now;
        for (const relay::Addr& a : candidates()) accept(identity(a.steam));
    }

    void* friends_ = nullptr;
    void* msgs_ = nullptr;
    const char* (*persona_)(void*) = nullptr;
    int (*friend_count_)(void*, int) = nullptr;
    uint64_t (*friend_by_index_)(void*, int, int) = nullptr;
    bool (*friend_game_)(void*, uint64_t, FriendGameInfo*) = nullptr;
    const char* (*friend_name_)(void*, uint64_t) = nullptr;
    int (*send_)(void*, const Identity*, const void*, uint32_t, int, int) = nullptr;
    int (*receive_)(void*, int, Message**, int) = nullptr;
    bool (*accept_)(void*, const Identity*) = nullptr;
    void (*release_)(Message*) = nullptr;
    int (*session_info_)(void*, const Identity*, SessionInfo*, SessionStatus*) = nullptr;
    bool (*close_)(void*, const Identity*) = nullptr;
    std::string problem_;
    std::string wanted_;
    std::vector<relay::Addr> playing_;
    std::map<uint64_t, double> sessions_;    // everyone this run talked to, and the last send while their session wasn't up
    double friends_at_ = -1e9, heard_at_ = -1e9, swept_at_ = -1e9;
};

}  // namespace

std::unique_ptr<relay::Link> relay::make_steam_link(const std::string& role, const std::string& peer) {
    return std::make_unique<SteamLink>(role, peer);
}
