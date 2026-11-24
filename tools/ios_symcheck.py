#!/usr/bin/env python3
"""
ios_symcheck.py - 맥 Mach-O(arm64)가 가져다 쓰는 심볼 중 iOS에 없는 것 찾기.

리타겟 후 dyld 가 로드 시점에 못 찾아서 죽는 심볼(= shim 이 제공해야 하는 것)을 미리 뽑는다.
iOS SDK 의 .tbd (예: theos/sdks iPhoneOS16.5.sdk) 를 기준으로 본다.

  ios_symcheck.py --sdk <iPhoneOS.sdk> FILE... [--shim-frameworks AppKit,Cocoa,...] [--json]

FILE 은 thin 또는 universal Mach-O. llvm-objdump (--dyld-info) 필요.
"""
import argparse, json, os, re, subprocess, sys, tempfile
from collections import defaultdict

FW_RE = re.compile(r"^/System/Library/Frameworks/(\w+)\.framework/(?:Versions/[A-Z]/)?\1$")

def tbd_docs(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    for doc in re.split(r"^---", txt, flags=re.M):
        m = re.search(r"^install-name:\s*'?([^'\n]+)'?", doc, re.M)
        if not m:
            continue
        name = m.group(1).strip()
        syms = set()
        for key, pre in (("symbols", "_"), ("weak-symbols", "_"), ("thread-local-symbols", "_"),
                         ("objc-classes", "_OBJC_CLASS_$_"), ("objc-eh-types", "_OBJC_EHTYPE_$_"),
                         ("objc-ivars", "_OBJC_IVAR_$_")):
            for blk in re.finditer(r"^\s*%s:\s*\[(.*?)\]" % re.escape(key), doc, re.M | re.S):
                for s in re.findall(r"'?([^,\s'\]]+)'?", blk.group(1)):
                    if key == "objc-classes":
                        syms.add("_OBJC_CLASS_$_" + s); syms.add("_OBJC_METACLASS_$_" + s)
                    elif key in ("symbols", "weak-symbols", "thread-local-symbols"):
                        syms.add(s)
                    else:
                        syms.add(pre + s)
        reexp = set()
        for blk in re.finditer(r"^reexported-libraries:(.*?)(?=^\S)", doc + "\nEND", re.M | re.S):
            reexp |= set(re.findall(r"'?(/[^,\s'\]]+)'?", blk.group(1)))
        yield name, syms, reexp

def load_sdk(sdk):
    lib = {}
    for root, _, files in os.walk(sdk):
        for f in files:
            if f.endswith(".tbd") and os.path.isfile(os.path.join(root, f)):
                for name, syms, reexp in tbd_docs(os.path.join(root, f)):
                    s, r = lib.get(name, (set(), set()))
                    lib[name] = (s | syms, r | reexp)
    return lib

def all_syms(lib, name, seen=None):
    seen = seen or set()
    if name in seen or name not in lib:
        return set()
    seen.add(name)
    s, r = lib[name]
    out = set(s)
    for x in r:
        out |= all_syms(lib, x, seen)
    return out

def ios_name(p):
    m = FW_RE.match(p)
    if m:
        return "/System/Library/Frameworks/%s.framework/%s" % (m.group(1), m.group(1)), m.group(1)
    return p, os.path.basename(p)

def imports(path):
    """(dylib 경로, 심볼, weak?) 목록"""
    with tempfile.TemporaryDirectory() as td:
        thin = os.path.join(td, "thin")
        if subprocess.run(["llvm-lipo", path, "-thin", "arm64", "-output", thin], capture_output=True).returncode != 0:
            thin = path
        used = subprocess.run(["llvm-objdump", "--macho", "--dylibs-used", thin], capture_output=True, text=True).stdout.splitlines()[1:]
        dylibs = [l.strip().split(" (")[0] for l in used]
        short = {}
        for d in dylibs:
            b = os.path.basename(d)
            short[b] = d
            short[re.sub(r"(\.\d+)*\.dylib$", "", b)] = d
            short[re.sub(r"\.dylib$", "", b)] = d
        out = []
        run = lambda opt: subprocess.run(["llvm-objdump", "--macho", opt, thin], capture_output=True, text=True).stdout.splitlines()
        # chained fixups (최신 링커): segment section address pointer type addend dylib symbol
        for l in run("--dyld-info"):
            f = l.split()
            if len(f) >= 8 and f[4] == "bind":
                out.append((short.get(f[6], f[6]), f[7], "weak" in l))
        # 옛 bind opcode: segment section address type addend dylib symbol [(weak_import)]
        for l in run("--bind"):
            f = l.split()
            if len(f) >= 7 and f[0].startswith("__") and f[3] == "pointer":
                out.append((short.get(f[5], f[5]), f[6], "weak_import" in l))
        # lazy bind: segment section address dylib symbol
        for l in run("--lazy-bind"):
            f = l.split()
            if len(f) >= 5 and f[0].startswith("__"):
                out.append((short.get(f[3], f[3]), f[4], False))
        return dylibs, out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk", required=True)
    ap.add_argument("--shim-frameworks", default="AppKit,Cocoa,Carbon,IOKit,CoreServices,CoreAudio,OpenGL,Quartz,ApplicationServices")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    lib = load_sdk(a.sdk)
    shimfw = set(a.shim_frameworks.split(","))
    cache = {}
    report = {}
    for path in a.files:
        _, imps = imports(path)
        missing = defaultdict(list)
        shim = defaultdict(list)
        for d, sym, weak in imps:
            if not d.startswith("/"):
                continue   # @rpath/@executable_path: 게임 자신의 라이브러리
            iname, short = ios_name(d)
            if short in shimfw:
                shim[short].append(sym); continue
            if iname not in lib:
                missing["(라이브러리 없음) " + short].append(sym); continue
            if iname not in cache:
                cache[iname] = all_syms(lib, iname)
            if sym not in cache[iname] and not weak:
                missing[short].append(sym)
        report[path] = {"shim": {k: sorted(set(v)) for k, v in shim.items()},
                        "missing": {k: sorted(set(v)) for k, v in missing.items()}}
    if a.json:
        json.dump(report, sys.stdout, ensure_ascii=False, indent=1); return
    for path, r in report.items():
        print("==", path)
        for k, v in sorted(r["shim"].items()):
            print("  shim %-14s %d" % (k, len(v)))
        for k, v in sorted(r["missing"].items()):
            print("  iOS에 없음 %s (%d): %s" % (k, len(v), " ".join(v)))
        if not r["missing"]:
            print("  iOS에 없는 심볼 없음")

if __name__ == "__main__":
    main()
