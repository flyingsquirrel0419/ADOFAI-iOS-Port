#!/usr/bin/env python3
"""
retarget.py - 얼불춤 맥 빌드의 arm64 Mach-O 를 iOS dyld 가 받아들이도록 고친다 (CyPort tools/ios_retarget.py 기반).

  1. universal -> arm64 slice
  2. LC_BUILD_VERSION platform macOS(1) -> iOS(2), minos/sdk
  3. 로드 경로:
       - iOS에 없는 맥 전용 프레임워크 (AppKit, Carbon, IOKit, CoreAudio, OpenGL ...)  -> shim
       - iOS에 있지만 일부 심볼이 없는 프레임워크 (CoreGraphics, CoreVideo, Security, AVFoundation, Foundation)
         -> 그 파일이 실제로 없는 심볼을 쓸 때만 shim (shim 이 원래 프레임워크를 re-export 하고 빠진 것만 정의)
       - AudioUnit -> AudioToolbox (iOS 에서는 AudioComponent*/AudioUnit* 가 여기 있음)
       - /System/Library/Frameworks/X.framework/Versions/A/X -> /System/Library/Frameworks/X.framework/X
       - @executable_path/../Frameworks/X -> @rpath/X
  4. 같은 경로로 합쳐진 로드 명령 중복 제거 + import ordinal 재번호 (LiveContainer 는 실행 파일을 dlopen 하므로 필수)
  5. 실행 파일에 LC_RPATH @executable_path/Contents/Frameworks 추가 (앱 번들 구조는 tools/make_app.py)
  코드 서명은 무효가 되므로 다시 서명할 것 (LiveContainer 는 자기 인증서로 서명).

사용:  retarget.py IN OUT [--minos 16.0] [--sdk 18.0]
       retarget.py --info FILE
"""
import argparse, os, re, struct, sys

LC_SEGMENT_64, LC_LOAD_DYLIB, LC_ID_DYLIB, LC_SYMTAB = 0x19, 0x0c, 0x0d, 0x2
LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD = 0x80000018, 0x8000001f, 0x80000023
LC_RPATH, LC_CODE_SIGNATURE, LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX = 0x8000001c, 0x1d, 0x32, 0x24
LC_DYLD_CHAINED_FIXUPS, LC_DYLD_INFO, LC_DYLD_INFO_ONLY = 0x80000034, 0x22, 0x80000022
DYLIB_CMDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD)
PLATFORM_MACOS, PLATFORM_IOS = 1, 2

SHIM = "@rpath/libADOFAIShim.dylib"
# Unity 는 bundlePath + "Contents/Resources/Data", "Contents/Frameworks", "Contents/PlugIns" 로 경로를 만든다.
# 그래서 iOS 앱 번들 안에도 맥과 같은 Contents/ 구조를 두고, 실행 파일만 번들 최상위에 둔다.
APP_FRAMEWORKS = "@executable_path/Contents/Frameworks"

# iOS 에 아예 없는 프레임워크: 전부 shim 으로
SHIM_FRAMEWORKS = {"AppKit", "Cocoa", "Carbon", "IOKit", "CoreServices", "CoreAudio", "OpenGL", "Quartz",
                   "SecurityFoundation", "ApplicationServices"}

# iOS 에 있지만 아래 심볼이 없음 (tools/ios_symcheck.py, iPhoneOS16.5 tbd 기준). 파일이 이 중 하나라도 쓰면 그 프레임워크를 shim 으로.
PARTIAL = {
    "Foundation": {"_OBJC_CLASS_$_NSAppleEventManager"},
    "AVFoundation": {"_AVCaptureSessionPreset320x240", "_AVCaptureSessionPreset960x540"},
    "CoreGraphics": {"_CGAssociateMouseAndMouseCursorPosition", "_CGDirectDisplayCopyCurrentMetalDevice", "_CGDisplayBounds",
                     "_CGDisplayCopyAllDisplayModes", "_CGDisplayCopyDisplayMode", "_CGDisplayHideCursor",
                     "_CGDisplayIDToOpenGLDisplayMask", "_CGDisplayIOServicePort", "_CGDisplayIsBuiltin",
                     "_CGDisplayModeCopyPixelEncoding", "_CGDisplayModeGetHeight", "_CGDisplayModeGetPixelHeight",
                     "_CGDisplayModeGetPixelWidth", "_CGDisplayModeGetWidth", "_CGDisplayModeRelease",
                     "_CGDisplayRegisterReconfigurationCallback", "_CGDisplayScreenSize", "_CGDisplayShowCursor",
                     "_CGEventCreateMouseEvent", "_CGEventSourceButtonState", "_CGEventSourceFlagsState",
                     "_CGEventSourceKeyState", "_CGGetActiveDisplayList", "_CGGetLastMouseDelta", "_CGMainDisplayID",
                     "_CGWarpMouseCursorPosition", "_CGShieldingWindowLevel"},
    "CoreVideo": {"_CVDisplayLinkCreateWithActiveCGDisplays", "_CVDisplayLinkCreateWithCGDisplay",
                  "_CVDisplayLinkGetActualOutputVideoRefreshPeriod", "_CVDisplayLinkGetNominalOutputVideoRefreshPeriod",
                  "_CVDisplayLinkRelease", "_CVDisplayLinkSetCurrentCGDisplay", "_CVDisplayLinkSetOutputCallback",
                  "_CVDisplayLinkStart", "_CVDisplayLinkStop", "_CVOpenGLTextureCacheCreate",
                  "_CVOpenGLTextureCacheCreateTextureFromImage", "_CVOpenGLTextureCacheFlush",
                  "_CVOpenGLTextureCacheRelease", "_CVOpenGLTextureGetName", "_CVOpenGLTextureGetTarget"},
    "Security": {"_SecCertificateCopyValues", "_SecCertificateGetData", "_SecKeychainItemCopyContent",
                 "_SecKeychainItemFreeContent", "_SecKeychainOpen", "_SecKeychainSearchCopyNext",
                 "_SecKeychainSearchCreateFromAttributes", "_SecTrustSettingsCopyCertificates",
                 "_SecTrustSettingsCopyTrustSettings", "_kSecOIDX509V1IssuerName", "_kSecOIDX509V1SubjectName"},
}
RENAME_FRAMEWORKS = {"AudioUnit": "AudioToolbox"}

FW_RE = re.compile(r"^/System/Library/Frameworks/(\w+)\.framework/(?:Versions/[A-Z]/)?\1$")

def ver(s):
    p = [int(x) for x in s.split(".")] + [0, 0]
    return (p[0] << 16) | (p[1] << 8) | p[2]

def cstr(b): return bytes(b).split(b"\0", 1)[0].decode("utf-8", "replace")

def thin_arm64(d):
    if struct.unpack_from(">I", d, 0)[0] != 0xcafebabe:
        return bytearray(d)
    for i in range(struct.unpack_from(">I", d, 4)[0]):
        cpu, sub, off, size, _al = struct.unpack_from(">IIIII", d, 8 + 20 * i)
        if cpu == 0x0100000c and (sub & 0xffffff) == 0:
            return bytearray(d[off:off + size])
    raise SystemExit("universal file has no arm64 slice")

def parse(d):
    magic, cpu, sub, ftype, ncmds, _sz, _fl, _ = struct.unpack_from("<IIIIIIII", d, 0)
    if magic != 0xfeedfacf: raise SystemExit("not a 64-bit little-endian Mach-O")
    if cpu != 0x0100000c: raise SystemExit("not arm64 (cputype=%#x)" % cpu)
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", d, off); cmds.append((cmd, off, sz)); off += sz
    return dict(ftype=ftype, sub=sub, cmds=cmds)

def name_of(d, off, sz):
    no = struct.unpack_from("<I", d, off + 8)[0]
    return no, cstr(d[off + no: off + sz])

def dylib_paths(d, m):
    return [name_of(d, off, sz)[1] for cmd, off, sz in m["cmds"] if cmd in DYLIB_CMDS]

# ---------- import 목록 (ordinal, 심볼) : chained fixups / bind opcode 둘 다 ----------

def _uleb(d, i):
    v = sh = 0
    while True:
        b = d[i]; i += 1; v |= (b & 0x7f) << sh; sh += 7
        if not b & 0x80: return v, i

def imports(d, m):
    out = []
    for cmd, off, sz in m["cmds"]:
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            dataoff = struct.unpack_from("<I", d, off + 8)[0]
            _v, _st, imp_off, sym_off, count, fmt, _sf = struct.unpack_from("<IIIIIII", d, dataoff)
            size = {1: 4, 2: 8, 3: 16}[fmt]
            for i in range(count):
                p = dataoff + imp_off + i * size
                if fmt == 3:
                    v = struct.unpack_from("<Q", d, p)[0]; lib, name_off = v & 0xffff, v >> 32
                else:
                    v = struct.unpack_from("<I", d, p)[0]; lib, name_off = v & 0xff, v >> 9
                s = dataoff + sym_off + name_off
                out.append((lib, cstr(d[s:s + 256])))
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            _ro, _rs, bo, bs, wo, ws, lo, ls = struct.unpack_from("<8I", d, off + 8)
            for start, size in ((bo, bs), (lo, ls)):
                i, end, lib, sym = start, start + size, 0, ""
                while i < end:
                    b = d[i]; op, imm = b & 0xf0, b & 0x0f; i += 1
                    if op == 0x10: lib = imm
                    elif op == 0x20: lib, i = _uleb(d, i)
                    elif op == 0x30: lib = -imm if imm else 0
                    elif op == 0x40:
                        j = i
                        while d[j]: j += 1
                        sym = cstr(d[i:j]); i = j + 1
                    elif op in (0x60, 0x70, 0x80, 0xa0): i = _uleb(d, i)[1]
                    elif op in (0x90, 0xb0): out.append((lib, sym))
                    elif op == 0xc0: i = _uleb(d, _uleb(d, i)[1])[1]; out.append((lib, sym))
                    elif op == 0xf0 and imm == 0: i = _uleb(d, i)[1]
    return out

# ---------- 경로 매핑 ----------

def plan_paths(d, m):
    """로드 명령 경로 -> 새 경로"""
    paths = dylib_paths(d, m)
    used = {}
    for lib, sym in imports(d, m):
        if 1 <= lib <= len(paths):
            used.setdefault(paths[lib - 1], set()).add(sym)
    out = {}
    for p in paths:
        mm = FW_RE.match(p)
        if mm:
            fw = mm.group(1)
            if fw in SHIM_FRAMEWORKS:
                out[p] = SHIM
            elif fw in PARTIAL and used.get(p, set()) & PARTIAL[fw]:
                out[p] = SHIM
            else:
                fw = RENAME_FRAMEWORKS.get(fw, fw)
                out[p] = "/System/Library/Frameworks/%s.framework/%s" % (fw, fw)
        elif p.startswith("@executable_path/../Frameworks/"):
            out[p] = "@rpath/" + p[len("@executable_path/../Frameworks/"):]
        elif p.startswith("@loader_path/../Frameworks/"):
            out[p] = "@rpath/" + p[len("@loader_path/../Frameworks/"):]
    return {k: v for k, v in out.items() if v != k}

def map_rpath(p):
    return {"@executable_path/../Frameworks": APP_FRAMEWORKS,
            "@loader_path/../Frameworks": APP_FRAMEWORKS}.get(p)

# ---------- 변환 ----------

def retarget(src, dst, minos, sdk):
    d = thin_arm64(open(src, "rb").read()); m = parse(d); log = []; seen = False
    plan = plan_paths(d, m)
    for cmd, off, sz in m["cmds"]:
        if cmd == LC_VERSION_MIN_MACOSX:
            raise SystemExit("legacy LC_VERSION_MIN_MACOSX: unsupported")
        if cmd == LC_BUILD_VERSION:
            seen = True
            if struct.unpack_from("<I", d, off + 8)[0] == PLATFORM_MACOS:
                struct.pack_into("<III", d, off + 8, PLATFORM_IOS, ver(minos), ver(sdk))
                log.append("build_version: macOS -> iOS (minos %s, sdk %s)" % (minos, sdk))
        elif cmd in DYLIB_CMDS or cmd in (LC_RPATH, LC_ID_DYLIB):
            no, old = name_of(d, off, sz)
            new = map_rpath(old) if cmd == LC_RPATH else (None if cmd == LC_ID_DYLIB and not old.startswith("@executable_path") else plan.get(old))
            if cmd == LC_ID_DYLIB and old.startswith("@executable_path/../Frameworks/"):
                new = "@rpath/" + old.split("/")[-1]
            if new and new != old:
                nb = new.encode() + b"\0"
                if no + len(nb) > sz:
                    if cmd == LC_RPATH:   # 자리가 모자란 rpath 는 그대로 둔다 (없는 경로는 dyld 가 건너뛴다)
                        log.append("rpath %s kept (no room for %s)" % (old, new)); continue
                    raise SystemExit("replacement too long: %s -> %s" % (old, new))
                d[off + no: off + sz] = nb + b"\0" * (sz - no - len(nb))
                log.append("%s -> %s" % (old, new))
    if not seen: raise SystemExit("no LC_BUILD_VERSION")
    log += dedupe_dylibs(d, m)
    if m["ftype"] == 2:   # MH_EXECUTE
        log += add_rpath(d, APP_FRAMEWORKS)
    # 남은 맥 경로 점검
    for p in dylib_paths(d, parse(d)):
        if "/Versions/" in p or p.startswith("@executable_path/../"):
            log.append("WARNING: unmapped path %s" % p)
    open(dst, "wb").write(d)
    return log

def add_rpath(d, path):
    m = parse(d); ncmds, szcmds = struct.unpack_from("<II", d, 16)
    for cmd, off, sz in m["cmds"]:
        if cmd == LC_RPATH and name_of(d, off, sz)[1] == path: return []
    first = len(d)
    for cmd, off, sz in m["cmds"]:
        if cmd != LC_SEGMENT_64: continue
        for i in range(struct.unpack_from("<I", d, off + 64)[0]):
            so = off + 72 + 80 * i; sf = struct.unpack_from("<I", d, so + 48)[0]
            if sf: first = min(first, sf)
    nb = path.encode() + b"\0"; size = (12 + len(nb) + 7) & ~7; end = 32 + szcmds
    if end + size > first or any(d[end:end + size]): raise SystemExit("rpath %s: no room after the load commands" % path)
    d[end:end + size] = struct.pack("<III", LC_RPATH, size, 12) + nb + b"\0" * (size - 12 - len(nb))
    struct.pack_into("<II", d, 16, ncmds + 1, szcmds + size)
    return ["rpath %s added" % path]

def dedupe_dylibs(d, m):
    """여러 맥 프레임워크가 같은 shim 경로로 합쳐져 생긴 중복 로드 명령 제거 + import ordinal 재번호 (CyPort 와 동일)."""
    dylibs = [(cmd, off, sz) for cmd, off, sz in m["cmds"] if cmd in DYLIB_CMDS]
    first, remap, drop = {}, {}, set()
    for i, (cmd, off, sz) in enumerate(dylibs, 1):
        path = name_of(d, off, sz)[1]
        if path in first:
            j = first[path]; drop.add(off)
            if cmd != LC_LOAD_WEAK_DYLIB and dylibs[j - 1][0] == LC_LOAD_WEAK_DYLIB:
                struct.pack_into("<I", d, dylibs[j - 1][1], LC_LOAD_DYLIB)
            remap[i] = remap[j]
        else:
            first[path] = i; remap[i] = len(first)
    if not drop: return []
    if max(remap) > 253: raise SystemExit("too many dylibs to renumber")
    for cmd, off, sz in m["cmds"]:
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            _ro, _rs, bo, bs, _wo, _ws, lo, ls = struct.unpack_from("<8I", d, off + 8)
            remap_bind_opcodes(d, bo, bs, remap); remap_bind_opcodes(d, lo, ls, remap)
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            dataoff = struct.unpack_from("<I", d, off + 8)[0]
            _v, _st, imp_off, _so, count, fmt, _sf = struct.unpack_from("<IIIIIII", d, dataoff)
            size = {1: 4, 2: 8, 3: 16}[fmt]
            for i in range(count):
                p = dataoff + imp_off + i * size
                if fmt == 3:
                    v = struct.unpack_from("<Q", d, p)[0]; lib = v & 0xffff
                    if lib in remap: struct.pack_into("<Q", d, p, (v & ~0xffff) | remap[lib])
                else:
                    v = struct.unpack_from("<I", d, p)[0]; lib = v & 0xff
                    if lib in remap: struct.pack_into("<I", d, p, (v & ~0xff) | remap[lib])
        elif cmd == LC_SYMTAB:
            symoff, nsyms = struct.unpack_from("<II", d, off + 8)
            for i in range(nsyms):
                e = symoff + 16 * i
                ntype, desc = d[e + 4], struct.unpack_from("<H", d, e + 6)[0]
                if ntype & 0xe0 or (ntype & 0x0e) != 0: continue
                lib = desc >> 8
                if lib in remap: struct.pack_into("<H", d, e + 6, (desc & 0xff) | (remap[lib] << 8))
    ncmds, sizeofcmds = struct.unpack_from("<II", d, 16)
    body = b"".join(bytes(d[off:off + sz]) for cmd, off, sz in m["cmds"] if off not in drop)
    d[32:32 + sizeofcmds] = body + b"\0" * (sizeofcmds - len(body))
    struct.pack_into("<II", d, 16, ncmds - len(drop), len(body))
    return ["removed %d duplicate dylib load command(s), import ordinals renumbered" % len(drop)]

def remap_bind_opcodes(d, start, size, remap):
    def skip_str(i):
        while d[i]: i += 1
        return i + 1
    i, end = start, start + size
    while i < end:
        b = d[i]; op, imm = b & 0xf0, b & 0x0f; i += 1
        if op == 0x10:
            if imm in remap: d[i - 1] = 0x10 | remap[imm]
        elif op == 0x20:
            v, j = _uleb(d, i)
            if v in remap:
                n, w = j - i, remap[v]
                if w < 16 and n == 1:
                    d[i] = w
                else:
                    for k in range(n): d[i + k] = ((w >> (7 * k)) & 0x7f) | (0x80 if k < n - 1 else 0)
            i = j
        elif op == 0x40: i = skip_str(i)
        elif op in (0x60, 0x70, 0x80, 0xa0): i = _uleb(d, i)[1]
        elif op == 0xc0: i = _uleb(d, _uleb(d, i)[1])[1]
        elif op == 0xf0 and imm == 0: i = _uleb(d, i)[1]

def info(path):
    d = thin_arm64(open(path, "rb").read()); m = parse(d)
    print(path, "filetype=%d" % m["ftype"])
    kinds = {LC_LOAD_DYLIB: "load", LC_LOAD_WEAK_DYLIB: "weak", LC_REEXPORT_DYLIB: "reexport", LC_ID_DYLIB: "id",
             LC_LOAD_UPWARD: "upward", LC_RPATH: "rpath"}
    for cmd, off, sz in m["cmds"]:
        if cmd == LC_BUILD_VERSION:
            pl, mo, sd = struct.unpack_from("<III", d, off + 8)
            print("  build_version platform=%d minos=%d.%d sdk=%d.%d" % (pl, mo >> 16, (mo >> 8) & 255, sd >> 16, (sd >> 8) & 255))
        elif cmd in kinds:
            print("  %-9s %s" % (kinds[cmd], name_of(d, off, sz)[1]))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("dst", nargs="?")
    ap.add_argument("--minos", default="16.0"); ap.add_argument("--sdk", default="18.0")
    ap.add_argument("--info", action="store_true")
    a = ap.parse_args()
    if a.info or not a.dst:
        info(a.src); return
    for l in retarget(a.src, a.dst, a.minos, a.sdk):
        print("retarget: %s: %s" % (os.path.basename(a.src), l))

if __name__ == "__main__":
    main()
