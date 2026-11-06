"""What a game crash was, from UE4SS's own minidump (ue4ss\\crash_*.dmp), with no debugger: the exception, where it hit, the
registers, the call site, and the frames the stack holds (module + offset, the mod's own UE4SS.dll and the game's PBZ.exe).

  python -I tools/netlab/crashdump.py <file.dmp> [frames]
  python -I tools/netlab/crashdump.py --newest [folder]      (the newest crash_*.dmp; default C:\\PBZDev\\platform\\steam\\ue4ss)

A call through a null pointer (an exception at address 0, "execute" in its parameters) leaves the caller's return address at
[rsp]: that's the call site, the line the crash really came from (11-07: PBZ.exe+0x153e1a6, reached from a mod call that gave
a passive ability to a player's figure and started it). A crash inside UE4SS.dll with a small address in rcx/rdx is usually a
call on an object that was gone: check the Lua the log shows just before it.
"""
import glob
import os
import struct
import sys

STREAM_THREADS, STREAM_MODULES, STREAM_MEMORY, STREAM_EXCEPTION, STREAM_MEMORY64 = 3, 4, 5, 6, 9
# Call sites seen before, and what they were (the game as of its November 4 update; an update moves them).
KNOWN = {
    "PBZ.exe+0x153e1a6": "an ability started on a player's figure that it can't run (a Phantom Edge's passive, sent as a "
                         "move): fixed in 1.7.0 (pbz.lua game.isMoveName, playMove)",
}
QUIET = ("ntdll", "KERNELBASE", "kernel32", "ucrtbase", "VCRUNTIME", "MSVCP")
CODES = {0xC0000005: "access violation", 0xC00000FD: "stack overflow", 0xC0000409: "stack buffer overrun",
         0x80000003: "breakpoint", 0xE06D7363: "C++ exception", 0xC000001D: "illegal instruction"}


class Dump:
    def __init__(self, path):
        self.b = open(path, "rb").read()
        if self.b[:4] != b"MDMP":
            raise SystemExit("not a minidump: " + path)
        n, d = self.u32(8), self.u32(12)
        self.streams = {}
        for i in range(n):
            t, size, rva = struct.unpack_from("<III", self.b, d + i * 12)
            self.streams.setdefault(t, []).append((size, rva))
        self.modules = []
        for _, rva in self.streams.get(STREAM_MODULES, []):
            for i in range(self.u32(rva)):
                o = rva + 4 + i * 108
                base, size = self.u64(o), self.u32(o + 8)
                self.modules.append((base, base + size, self.string(self.u32(o + 20)).split("\\")[-1]))
        self.modules.sort()
        self.regions = []
        for _, rva in self.streams.get(STREAM_MEMORY, []):
            for i in range(self.u32(rva)):
                o = rva + 4 + i * 16
                self.regions.append((self.u64(o), self.u32(o + 8), self.u32(o + 12)))
        for _, rva in self.streams.get(STREAM_MEMORY64, []):
            count, at = self.u64(rva), self.u64(rva + 8)
            for i in range(count):
                o = rva + 16 + i * 16
                start, size = self.u64(o), self.u64(o + 8)
                self.regions.append((start, size, at))
                at += size

    def u32(self, o):
        return struct.unpack_from("<I", self.b, o)[0]

    def u64(self, o):
        return struct.unpack_from("<Q", self.b, o)[0]

    def string(self, rva):
        return self.b[rva + 4:rva + 4 + self.u32(rva)].decode("utf-16-le", "replace")

    def where(self, addr):
        for lo, hi, name in self.modules:
            if lo <= addr < hi:
                return "%s+0x%x" % (name, addr - lo)
        return None

    def read64(self, addr):
        for start, size, at in self.regions:
            if start <= addr and addr + 8 <= start + size:
                return self.u64(at + (addr - start))
        return None


def report(path, frames=40):
    d = Dump(path)
    print(os.path.basename(path))
    for _, rva in d.streams.get(STREAM_EXCEPTION, []):
        tid, code, addr = d.u32(rva), d.u32(rva + 8), d.u64(rva + 24)
        nparams = d.u32(rva + 32)
        params = [d.u64(rva + 40 + 8 * k) for k in range(min(nparams, 3))]
        ctx = d.u32(rva + 164)
        rsp, rip = d.u64(ctx + 0x98), d.u64(ctx + 0xF8)
        what = CODES.get(code, "0x%08x" % code)
        if code == 0xC0000005 and params:
            what += " (%s 0x%x)" % ({0: "read", 1: "write", 8: "execute"}.get(params[0], "?"), params[1] if len(params) > 1 else 0)
        print("  %s at 0x%x (%s), thread %d" % (what, addr, d.where(addr) or "nowhere: a call through a null or stale pointer",
                                                tid))
        regs = [("rax", 0x78), ("rcx", 0x80), ("rdx", 0x88), ("rbx", 0x90), ("rbp", 0xA0), ("rsi", 0xA8), ("rdi", 0xB0),
                ("r8", 0xB8), ("r9", 0xC0)]
        print("  registers: " + "  ".join("%s=0x%x%s" % (n, d.u64(ctx + o), " (" + d.where(d.u64(ctx + o)) + ")"
                                                         if d.where(d.u64(ctx + o)) else "") for n, o in regs))
        top = d.read64(rsp)
        site = d.where(addr) or (d.where(top) if addr < 0x10000 and top is not None else None)
        if addr < 0x10000 and top is not None and d.where(top):
            print("  called from: %s (the return address at [rsp])" % d.where(top))
        if site in KNOWN:
            print("  seen before: " + KNOWN[site])
        print("  frames on the stack (most recent first):")
        shown = 0
        for k in range(4096):
            v = d.read64(rsp + 8 * k)
            if v is None:
                break
            w = d.where(v)
            if w and not w.startswith(QUIET):
                print("    [rsp+0x%x] %s" % (8 * k, w))
                shown += 1
                if shown >= frames:
                    break


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    if args[0] == "--newest":
        folder = args[1] if len(args) > 1 else r"C:\PBZDev\platform\steam\ue4ss"
        dumps = sorted(glob.glob(os.path.join(folder, "crash_*.dmp")), key=os.path.getmtime)
        if not dumps:
            raise SystemExit("no crash_*.dmp in " + folder)
        report(dumps[-1])
    else:
        report(args[0], int(args[1]) if len(args) > 1 else 40)


if __name__ == "__main__":
    main()
