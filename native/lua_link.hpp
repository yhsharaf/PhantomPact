// Direct calls from the mod's Lua into this DLL, with no file in between. The mod gets each function with
// package.loadlib(main.dll, "pp_<name>"): main.dll is already loaded, so that only finds the export.
//
// UE4SS keeps Lua's C functions to itself, but it exports its own wrapper class for C++ mods, RC::LuaMadeSimple::Lua, and
// each of those methods is a thin step around one Lua call. Their first field is the lua_State*, so a one-field stand-in
// for the object is enough. All of this is looked up by name and checked, and if anything is missing every pp_ function
// returns nothing, which the mod reports instead of crashing.
#pragma once
#include "relay.hpp"

namespace lua_link {

struct State {
    void* lua;
};

struct Api {
    int (*top)(const State*);
    bool (*is_string)(const State*, int);
    double (*get_number)(const State*, int);                                 // reads the value and removes it
    std::string_view* (*get_string)(const State*, std::string_view*, int);   // same; only ever on a string
    void (*set_number)(const State*, double);
    void (*set_string)(const State*, const char*, size_t);
    void (*set_nil)(const State*);
};

inline const Api* api() {
    static const Api* found = []() -> const Api* {
        HMODULE ue4ss = GetModuleHandleW(L"UE4SS.dll");
        if (!ue4ss) return nullptr;
        // mov rax,[rcx] / ret: the lua_State* is the object's first field, as State assumes.
        auto state_getter = reinterpret_cast<const unsigned char*>(GetProcAddress(ue4ss, "?get_lua_state@Lua@LuaMadeSimple@RC@@QEBAPEAUlua_State@@XZ"));
        if (!state_getter || std::memcmp(state_getter, "\x48\x8B\x01\xC3", 4) != 0) return nullptr;
        static Api a{};
        auto bind = [&](auto& slot, const char* name) {
            slot = reinterpret_cast<std::remove_reference_t<decltype(slot)>>(GetProcAddress(ue4ss, name));
            return slot != nullptr;
        };
        const bool all = bind(a.top, "?get_stack_size@Lua@LuaMadeSimple@RC@@QEBAHXZ") &&
                         bind(a.is_string, "?is_string@Lua@LuaMadeSimple@RC@@QEBA_NH@Z") &&
                         bind(a.get_number, "?get_number@Lua@LuaMadeSimple@RC@@QEBANH@Z") &&
                         bind(a.get_string, "?get_string@Lua@LuaMadeSimple@RC@@QEBA?AV?$basic_string_view@DU?$char_traits@D@std@@@std@@H@Z") &&
                         bind(a.set_number, "?set_number@Lua@LuaMadeSimple@RC@@QEBAXN@Z") &&
                         bind(a.set_string, "?set_string@Lua@LuaMadeSimple@RC@@QEBAXPEBD_K@Z") &&
                         bind(a.set_nil, "?set_nil@Lua@LuaMadeSimple@RC@@QEBAXXZ");
        return all ? &a : nullptr;
    }();
    return found;
}

// The first argument as a string, limited to what fits a packet.
inline bool text_arg(const Api* a, const State& s, std::string& out) {
    if (a->top(&s) < 1 || !a->is_string(&s, 1)) return false;
    std::string_view view;
    a->get_string(&s, &view, 1);
    out.assign(view.substr(0, relay::MAX_TEXT));
    return true;
}

inline int push_text(const Api* a, const State& s, const std::string& text) {
    if (text.empty()) return 0;
    a->set_string(&s, text.data(), text.size());
    return 1;
}

// FNV-1a: both PCs turn an area's name into the same number, which fits in every sample.
inline uint32_t name_hash(std::string_view name) {
    uint32_t h = 2166136261u;
    for (char c : name) h = (h ^ static_cast<unsigned char>(c)) * 16777619u;
    return h;
}

}  // namespace lua_link

// Seconds on the clock packets are stamped with: finer than os.clock(), which moves in whole milliseconds.
extern "C" __declspec(dllexport) int pp_now(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    a->set_number(&s, relay::clock_ms() / 1000.0);
    return 1;
}

// The PC's own clock in seconds, which two copies on one PC share: for the bench in tools/netlab.
extern "C" __declspec(dllexport) int pp_wall(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    a->set_number(&s, relay::monotonic());
    return 1;
}

// pp_state(x, y, z, yaw, vx, vy, vz, hp, maxhp, map, flags): the local player, sent at once.
extern "C" __declspec(dllexport) int pp_state(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    if (a->top(&s) < 11) return 0;
    relay::Sample out;
    out.ms = static_cast<uint32_t>(relay::clock_ms());
    const auto next = [&] { return static_cast<float>(a->get_number(&s, 1)); };
    out.x = next();
    out.y = next();
    out.z = next();
    out.yaw = next();
    out.vx = next();
    out.vy = next();
    out.vz = next();
    out.hp = next();
    out.max_hp = next();
    out.map = static_cast<uint32_t>(a->get_number(&s, 1));
    out.flags = static_cast<uint16_t>(a->get_number(&s, 1));
    relay::mail.post_sample(out);
    return 0;
}

// pp_event(text): must arrive (deaths, hits, loot). pp_quick(text): worth nothing late (moves, hit reactions).
// pp_enemy(text): one enemy's current state.
extern "C" __declspec(dllexport) int pp_event(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    std::string text;
    if (text_arg(a, State{lua}, text)) relay::mail.post_sure(std::move(text));
    return 0;
}

extern "C" __declspec(dllexport) int pp_quick(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    std::string text;
    if (text_arg(a, State{lua}, text)) relay::mail.post_quick(std::move(text));
    return 0;
}

extern "C" __declspec(dllexport) int pp_enemy(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    std::string text;
    if (text_arg(a, State{lua}, text)) relay::mail.post_enemy(std::move(text));
    return 0;
}

// x, y, z, yaw, vx, vy, vz, hp, maxhp, map, flags, ms since the last packet, ms played behind: where to show the partner
// this frame. Nothing until they've been heard.
extern "C" __declspec(dllexport) int pp_partner(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    relay::Sample p;
    double silence = 0, delay = 0;
    if (!relay::mail.partner(relay::clock_ms(), p, silence, delay)) return 0;
    const State s{lua};
    for (double v : {static_cast<double>(p.x), static_cast<double>(p.y), static_cast<double>(p.z), static_cast<double>(p.yaw),
                     static_cast<double>(p.vx), static_cast<double>(p.vy), static_cast<double>(p.vz), static_cast<double>(p.hp),
                     static_cast<double>(p.max_hp), static_cast<double>(p.map), static_cast<double>(p.flags), silence, delay})
        a->set_number(&s, v);
    return 13;
}

// With more than two players (party.hpp). pp_party(): how many at most, and this player's slot; nothing with two.
extern "C" __declspec(dllexport) int pp_party(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    int players = 0, slot = 0;
    if (!relay::mail.party(players, slot)) return 0;
    const State s{lua};
    a->set_number(&s, players);
    a->set_number(&s, slot);
    return 2;
}

// pp_player(slot): as pp_partner, for the player in that slot.
extern "C" __declspec(dllexport) int pp_player(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    if (a->top(&s) < 1) return 0;
    const int slot = static_cast<int>(a->get_number(&s, 1));
    relay::Sample p;
    double silence = 0, delay = 0;
    if (!relay::mail.player(slot, relay::clock_ms(), p, silence, delay)) return 0;
    for (double v : {static_cast<double>(p.x), static_cast<double>(p.y), static_cast<double>(p.z), static_cast<double>(p.yaw),
                     static_cast<double>(p.vx), static_cast<double>(p.vy), static_cast<double>(p.vz), static_cast<double>(p.hp),
                     static_cast<double>(p.max_hp), static_cast<double>(p.map), static_cast<double>(p.flags), silence, delay})
        a->set_number(&s, v);
    return 13;
}

// pp_send_to(slot, text): a sure event for that guest alone.
extern "C" __declspec(dllexport) int pp_send_to(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    if (a->top(&s) < 2) return 0;
    const int slot = static_cast<int>(a->get_number(&s, 1));
    std::string text;
    if (text_arg(a, s, text)) relay::mail.post_to(slot, std::move(text));
    return 0;
}

// One line per event since the last call, or nothing.
extern "C" __declspec(dllexport) int pp_events(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    return a ? push_text(a, State{lua}, relay::mail.take_events(relay::clock_ms())) : 0;
}

// One line per enemy update since the last call, or nothing.
extern "C" __declspec(dllexport) int pp_enemies(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    return a ? push_text(a, State{lua}, relay::mail.take_enemies()) : 0;
}

// The same line as net_status.txt.
extern "C" __declspec(dllexport) int pp_status(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    return a ? push_text(a, State{lua}, relay::mail.status()) : 0;
}

// The text on the Windows clipboard, for the online panel's Paste button. Only ever read when that button is pressed.
extern "C" __declspec(dllexport) int pp_paste(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    std::string text;
    if (OpenClipboard(nullptr)) {
        if (HANDLE h = GetClipboardData(CF_UNICODETEXT)) {
            if (const auto* w = static_cast<const wchar_t*>(GlobalLock(h))) {
                const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
                if (n > 1 && n <= 512) {
                    text.resize(n - 1);
                    WideCharToMultiByte(CP_UTF8, 0, w, -1, text.data(), n, nullptr, nullptr);
                }
                GlobalUnlock(h);
            }
        }
        CloseClipboard();
    }
    return push_text(a, State{lua}, text);
}

// pp_map(name): the area the local player is in. Returns its number, for pp_state.
extern "C" __declspec(dllexport) int pp_map(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    std::string name;
    if (!text_arg(a, s, name)) return 0;
    const uint32_t hash = name_hash(name);
    relay::mail.post_map(std::move(name));
    a->set_number(&s, hash);
    return 1;
}

// Sync turned on: a new session, and the partner is told.
extern "C" __declspec(dllexport) int pp_reset(void* lua) {
    if (!lua_link::api()) return 0;
    relay::mail.reset();
    (void)lua;
    return 0;
}

// The player left: the relay closes its socket and waits for the next net_start.txt. Returns at once; the status line
// says stopped=yes when it's done.
extern "C" __declspec(dllexport) int pp_stop(void* lua) {
    if (!lua_link::api()) return 0;
    relay::mail.ask_stop();
    (void)lua;
    return 0;
}

// Reading a character through UE4SS costs 30-100 us a property, and the net loop reads the player every frame and every
// enemy ten times a second. These read the same memory directly, with no object made for Lua. The mod finds the offsets
// once through the game's own reflection (pp_layout), checks them against a normal read before using them, and only passes
// objects it holds; a pointer that went stale anyway ends in a caught access violation, not a crash.
namespace lua_link {

struct Layout {
    bool known = false;
    ptrdiff_t root = 0, location = 0, rotation = 0, attach_parent = 0;  // actor -> scene component -> its fields
    ptrdiff_t movement = 0, velocity = 0, mode = 0;                     // actor -> movement component -> its fields
    ptrdiff_t attributes = 0, health = 0, max_health = 0, posture = 0;  // actor -> attribute set -> CurrentValue floats
};
inline Layout layout;

struct Character {
    double x, y, z, yaw, vx, vy, vz, mode, hp, max_hp, posture;
};

// A read of memory that may be gone: a bad address, but also a guard page or a mapped page that can't be paged in, which
// took the game down as they weren't caught.
inline bool bad_read(DWORD code) {
    return code == EXCEPTION_ACCESS_VIOLATION || code == STATUS_GUARD_PAGE_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR;
}

template <typename T>
inline T field(uintptr_t object, ptrdiff_t offset) {
    return *reinterpret_cast<const T*>(object + offset);
}

// False if a pointer on the way is empty, stale, or the actor is attached to something: its location is then relative to
// that, so the caller asks the game. No C++ objects in here: __try can't live with their unwinding.
inline bool read_character(uintptr_t actor, const Layout& l, Character& out) {
    __try {
        const auto root = field<uintptr_t>(actor, l.root);
        const auto movement = field<uintptr_t>(actor, l.movement);
        const auto attributes = field<uintptr_t>(actor, l.attributes);
        if (!root || !movement || !attributes || field<uintptr_t>(root, l.attach_parent)) return false;
        out.x = field<double>(root, l.location);
        out.y = field<double>(root, l.location + 8);
        out.z = field<double>(root, l.location + 16);
        out.yaw = std::remainder(field<double>(root, l.rotation + 8), 360.0);  // as K2_GetActorRotation gives it, -180..180
        out.vx = field<double>(movement, l.velocity);
        out.vy = field<double>(movement, l.velocity + 8);
        out.vz = field<double>(movement, l.velocity + 16);
        out.mode = field<uint8_t>(movement, l.mode);
        out.hp = field<float>(attributes, l.health);
        out.max_hp = field<float>(attributes, l.max_health);
        out.posture = field<float>(attributes, l.posture);
        return true;
    } __except (bad_read(GetExceptionCode()) ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        return false;
    }
}

inline uintptr_t read_pointer(uintptr_t object, ptrdiff_t offset) {
    __try {
        return field<uintptr_t>(object, offset);
    } __except (bad_read(GetExceptionCode()) ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        return 0;
    }
}

}  // namespace lua_link

// pp_layout(root, location, rotation, attach parent, movement, velocity, mode, attributes, health, max health, posture).
extern "C" __declspec(dllexport) int pp_layout(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    if (a->top(&s) < 11) return 0;
    Layout l;
    const auto next = [&] { return static_cast<ptrdiff_t>(a->get_number(&s, 1)); };
    l.root = next();
    l.location = next();
    l.rotation = next();
    l.attach_parent = next();
    l.movement = next();
    l.velocity = next();
    l.mode = next();
    l.attributes = next();
    l.health = next();
    l.max_health = next();
    l.posture = next();
    l.known = true;
    layout = l;
    return 0;
}

// pp_read(actor address): x, y, z, yaw, vx, vy, vz, movement mode, health, max health, posture; nothing if it can't be read.
extern "C" __declspec(dllexport) int pp_read(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    if (!layout.known || a->top(&s) < 1) return 0;
    Character c;
    if (!read_character(static_cast<uintptr_t>(a->get_number(&s, 1)), layout, c)) return 0;
    for (double v : {c.x, c.y, c.z, c.yaw, c.vx, c.vy, c.vz, c.mode, c.hp, c.max_hp, c.posture}) a->set_number(&s, v);
    return 11;
}

// pp_pointer(object address, offset): the pointer kept at that offset, 0 if it can't be read.
extern "C" __declspec(dllexport) int pp_pointer(void* lua) {
    using namespace lua_link;
    const Api* a = api();
    if (!a) return 0;
    const State s{lua};
    if (a->top(&s) < 2) return 0;
    const auto object = static_cast<uintptr_t>(a->get_number(&s, 1));
    const auto offset = static_cast<ptrdiff_t>(a->get_number(&s, 1));
    a->set_number(&s, static_cast<double>(read_pointer(object, offset)));
    return 1;
}
