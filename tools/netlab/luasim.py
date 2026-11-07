"""Runs the mod's real Lua with no game: tools/netlab/sim holds a stand-in for UE4SS and the game, one per player, in one process.
This PC has no Lua of its own, so a Lua DLL does the running: Cheat Engine's lua53-64.dll will do (UE4SS has 5.4; the mod uses
nothing that differs), or name one in PP_LUA_DLL. Nothing here touches the game.

  python -I tools/netlab/luasim.py four                        the rules with four players
  python -I tools/netlab/luasim.py four <folder of old Scripts>  the same rules on old scripts: what a new test catches
  python -I tools/netlab/luasim.py two <folder of old Scripts>  two players, old against new: every call must match
  python -I tools/netlab/luasim.py pvp                         a whole PvP match (F6), two players
  python -I tools/netlab/luasim.py pvp <folder of old Scripts>   the same match on old scripts
"""
import ctypes
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CANDIDATES = [os.environ.get("PP_LUA_DLL"), r"C:\Program Files\Cheat Engine 7.5\lua53-64.dll"]


def find_dll():
    for path in CANDIDATES:
        if path and os.path.exists(path):
            return path
    sys.exit("No Lua DLL: set PP_LUA_DLL to a 64-bit Lua 5.3 or 5.4 DLL.")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    dll = find_dll()
    lua = ctypes.CDLL(dll)
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lua.lua_tolstring.restype = ctypes.c_char_p
    lua.lua_pushstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.lua_setglobal.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    state = lua.luaL_newstate()
    lua.luaL_openlibs(state)
    repo = os.path.normpath(os.path.join(HERE, "..", ".."))
    values = {"SIM_DIR": os.path.join(HERE, "sim"), "SIM_REPO": repo, "SIM_MODE": sys.argv[1], "SIM_OLD": sys.argv[2] if len(sys.argv) > 2 else "", "SIM_STEPS": sys.argv[3] if len(sys.argv) > 3 else ""}
    for name, value in values.items():
        lua.lua_pushstring(state, value.replace("\\", "/").encode("utf-8"))
        lua.lua_setglobal(state, name.encode())
    main_file = os.path.join(HERE, "sim", "main.lua").encode("utf-8")
    if lua.luaL_loadfilex(state, main_file, None) != 0 or lua.lua_pcallk(state, 0, 1, 0, None, None) != 0:
        print("Lua error:", lua.lua_tolstring(state, -1, None).decode("utf-8", "replace"))
        return 2
    result = lua.lua_tolstring(state, -1, None)
    return 0 if result == b"pass" else 1


if __name__ == "__main__":
    sys.exit(main())
