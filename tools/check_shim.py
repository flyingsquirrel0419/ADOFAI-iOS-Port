#!/usr/bin/env python3
"""
check_shim.py - 리타겟한 게임 바이너리가 shim 에서 찾는 심볼이 전부 있는지 확인.

shim 이 찾을 수 있는 것 = shim 자신의 export (libADOFAIShim.exports.txt, CI 산출물)
                        + shim 이 re-export 하는 iOS 프레임워크 (iOS SDK .tbd 기준)

  check_shim.py --exports libADOFAIShim.exports.txt --sdk iPhoneOS.sdk RETARGETED_FILE...
없는 게 있으면 목록을 찍고 종료 코드 1.
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import retarget as r
import ios_symcheck as c

REEXPORTED = ["Foundation", "CoreGraphics", "CoreVideo", "Security", "AVFoundation"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exports", required=True)
    ap.add_argument("--sdk", required=True)
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    have = set(l.strip() for l in open(a.exports) if l.strip())
    lib = c.load_sdk(a.sdk)
    for fw in REEXPORTED:
        have |= c.all_syms(lib, "/System/Library/Frameworks/%s.framework/%s" % (fw, fw))
    bad = 0
    for f in a.files:
        d = r.thin_arm64(open(f, "rb").read()); m = r.parse(d); paths = r.dylib_paths(d, m)
        need = sorted({s for lib_, s in r.imports(d, m) if 1 <= lib_ <= len(paths) and paths[lib_ - 1] == r.SHIM})
        miss = [s for s in need if s not in have]
        print("%-40s shim imports %4d, missing %d%s" % (os.path.basename(f), len(need), len(miss), (": " + " ".join(miss)) if miss else ""))
        bad += len(miss)
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
