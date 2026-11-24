#!/usr/bin/env python3
"""
make_app.py - 본인 스팀 계정으로 받은 얼불춤 맥 빌드 + shim -> iOS 앱 (.ipa, 서명 안 됨; LiveContainer/SideStore 가 서명)

  make_app.py --mac "ADanceOfFireAndIce.app" --shim libADOFAIShim.dylib [--mono-aot DIR] --out ADOFAI.ipa [--split]

--split: 게임 데이터(2.6 GB)를 IPA 에서 빼고 따로 <out 이름>-data.zip 으로 만든다.
  데이터 zip 은 한 번만 폰으로 옮겨 이 앱의 Documents/ADOFAIData 에 풀고, 이후 테스트 빌드는 가벼운 IPA 만 설치.
  (shim 이 시작할 때 앱 번들의 Contents/Resources/Data 를 Documents/ADOFAIData 로 잇는다)

앱 번들 구조 (Unity 가 bundlePath + "Contents/Resources/Data" 등으로 경로를 만들기 때문에 맥 구조를 유지):
  ADOFAI.app/
    ADanceOfFireAndIce            실행 파일 (리타겟)
    Info.plist                    iOS 용
    Contents/Info.plist           원래 것 (Unity 가 읽을 수도 있어서)
    Contents/Frameworks/          UnityPlayer, libmono*, libADOFAIShim (리타겟)
    Contents/PlugIns/             플러그인 (리타겟)
    Contents/Resources/Data/      게임 데이터 (그대로)
    Contents/MonoBleedingEdge/    Mono 설정

--mono-aot DIR: Mono 인터프리터 모드용 파일 (CI mono-interp 산출물 "mono-aot-ios"):
    mscorlib.dll          같은 커밋 소스로 빌드한 것 -> Data/Managed/mscorlib.dll 을 이것으로 바꾼다 (AOT 이미지는 어셈블리 GUID 가 맞아야 함)
    libADOFAIAot.dylib    mscorlib 의 --aot=interp,static 이미지 (iOS 용) -> Contents/Frameworks/ (shim 이 mono_aot_register_module 로 등록)
  없으면 앱은 만들지만 Mono 초기화에서 멈춘다 (로그에 표시됨).

게임 파일은 이 도구를 돌리는 사람 본인의 것만 쓴다. 결과 .ipa 는 배포하지 말 것.
"""
import argparse, os, plistlib, shutil, stat, struct, sys, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import retarget as rt

MACHO_MAGICS = (0xfeedfacf, 0xcafebabe, 0xbebafeca, 0xcffaedfe)

def is_macho(path):
    try:
        with open(path, "rb") as f:
            b = f.read(4)
        return len(b) == 4 and struct.unpack(">I", b)[0] in MACHO_MAGICS
    except OSError:
        return False

def log(*a): print("make_app:", *a, flush=True)

def copytree_link(src, dst):
    """큰 데이터는 같은 파일시스템이면 하드링크 (2.6 GB 복사 방지), 아니면 복사"""
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        os.makedirs(os.path.join(dst, rel), exist_ok=True)
        for f in files:
            s, d = os.path.join(root, f), os.path.join(dst, rel, f)
            try:
                os.link(s, d)
            except OSError:
                shutil.copy2(s, d)

def ios_info(mac_info, bundle_id):
    p = {
        "CFBundleExecutable": mac_info["CFBundleExecutable"],
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "ADOFAI",
        "CFBundleDisplayName": "ADOFAI (port)",
        "CFBundleShortVersionString": mac_info.get("CFBundleShortVersionString", "1.0"),
        "CFBundleVersion": mac_info.get("CFBundleVersion", "1"),
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "MinimumOSVersion": "16.0",
        "UIDeviceFamily": [1, 2],
        "UIRequiresFullScreen": True,
        "UIStatusBarHidden": True,
        "UILaunchScreen": {},                  # 없으면 iOS 가 옛 화면 크기 호환 모드로 띄운다
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UIApplicationSupportsIndirectInputEvents": True,
        "GCSupportsControllerUserInteraction": True,
        "UIFileSharingEnabled": True,           # Documents (adofaishim.log, ADOFAIShim.plist) 를 파일 앱에서
        "LSSupportsOpeningDocumentsInPlace": True,
        "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        "UnityBuildNumber": mac_info.get("UnityBuildNumber", ""),
        "ADOFAIPortSource": "Steam macOS build %s" % mac_info.get("CFBundleShortVersionString", "?"),
    }
    return p

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", required=True, help="ADanceOfFireAndIce.app (스팀 맥 빌드)")
    ap.add_argument("--shim", required=True, help="libADOFAIShim.dylib (CI shim 산출물)")
    ap.add_argument("--mono-aot", help="mscorlib.dll + mscorlib.dll.dylib 이 있는 폴더 (CI mono-interp 산출물)")
    ap.add_argument("--out", required=True, help="출력 .ipa")
    ap.add_argument("--work", help="작업 폴더 (기본: <out>.work)")
    ap.add_argument("--bundle-id", default="io.github.adofai-ios-port")
    ap.add_argument("--split", action="store_true", help="게임 데이터를 IPA 에서 빼서 <out>-data.zip 으로")
    ap.add_argument("--minos", default="16.0"); ap.add_argument("--sdk", default="18.0")
    a = ap.parse_args()

    mac = os.path.abspath(a.mac)
    C = os.path.join(mac, "Contents")
    mac_info = plistlib.load(open(os.path.join(C, "Info.plist"), "rb"))
    exe_name = mac_info["CFBundleExecutable"]
    work = os.path.abspath(a.work or a.out + ".work")
    app = os.path.join(work, "Payload", "ADOFAI.app")
    if os.path.exists(work):
        shutil.rmtree(work)
    AC = os.path.join(app, "Contents")
    os.makedirs(AC)

    # 1. 데이터 / 리소스 (Mach-O 가 아닌 것)
    log("copying game data (hard links when possible)")
    copytree_link(os.path.join(C, "Resources"), os.path.join(AC, "Resources"))
    if os.path.isdir(os.path.join(C, "MonoBleedingEdge")):
        copytree_link(os.path.join(C, "MonoBleedingEdge"), os.path.join(AC, "MonoBleedingEdge"))
    shutil.copy2(os.path.join(C, "Info.plist"), os.path.join(AC, "Info.plist"))
    nib = os.path.join(AC, "Resources", "MainMenu.nib")
    if os.path.isdir(nib):
        shutil.rmtree(nib)   # AppKit nib: iOS 에서 못 씀 (shim 이 대신 PlayerAppDelegate 를 만든다)

    # 2. Mach-O 리타겟
    n = 0
    def retarget(src, dst):
        nonlocal n
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        for l in rt.retarget(src, dst, a.minos, a.sdk):
            if l.startswith("WARNING"):
                log("  %s: %s" % (os.path.basename(src), l))
        os.chmod(dst, 0o755); n += 1
    retarget(os.path.join(C, "MacOS", exe_name), os.path.join(app, exe_name))
    for sub in ("Frameworks", "PlugIns"):
        base = os.path.join(C, sub)
        for root, dirs, files in os.walk(base):
            for f in files:
                s = os.path.join(root, f)
                d = os.path.join(AC, sub, os.path.relpath(s, base))
                if "_CodeSignature" in s or f == "CodeResources":
                    continue
                if is_macho(s):
                    retarget(s, d)
                else:
                    os.makedirs(os.path.dirname(d), exist_ok=True); shutil.copy2(s, d)
    log("retargeted %d Mach-O files" % n)

    # 3. shim
    shutil.copy2(a.shim, os.path.join(AC, "Frameworks", "libADOFAIShim.dylib"))

    # 4. Mono 인터프리터 모드 파일
    managed = os.path.join(AC, "Resources", "Data", "Managed")
    if a.mono_aot:
        for f in ("mscorlib.dll", "libADOFAIAot.dylib"):
            if not os.path.exists(os.path.join(a.mono_aot, f)):
                sys.exit("make_app: %s missing in --mono-aot" % f)
        d = os.path.join(managed, "mscorlib.dll")
        os.unlink(d)   # 하드링크 끊기 (원본 게임 파일은 그대로)
        shutil.copy2(os.path.join(a.mono_aot, "mscorlib.dll"), d)
        shutil.copy2(os.path.join(a.mono_aot, "libADOFAIAot.dylib"), os.path.join(AC, "Frameworks", "libADOFAIAot.dylib"))
        log("mono: mscorlib.dll (same-commit build) + libADOFAIAot.dylib (interp AOT) installed")
    else:
        log("WARNING: no --mono-aot: Mono will stop at startup (interpreter mode needs the mscorlib AOT image)")

    # 5. Info.plist
    plistlib.dump(ios_info(mac_info, a.bundle_id), open(os.path.join(app, "Info.plist"), "wb"))

    # 6. IPA (무압축: 데이터 대부분이 이미 압축돼 있고 2 GB 넘음)
    out = os.path.abspath(a.out)
    data_dir = os.path.join(AC, "Resources", "Data")
    if a.split:
        data_zip = os.path.splitext(out)[0] + "-data.zip"
        log("writing %s (put its ADOFAIData folder in the app's Documents once)" % data_zip)
        write_zip(data_zip, data_dir, "ADOFAIData")
        shutil.rmtree(data_dir)
    log("writing %s" % out)
    write_zip(out, os.path.join(work, "Payload"), "Payload")
    log("done: %s (%.2f GB)" % (out, os.path.getsize(out) / 1e9))

def write_zip(out, src, arcroot):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        for root, dirs, files in os.walk(src):
            for f in files:
                p = os.path.join(root, f)
                arc = os.path.join(arcroot, os.path.relpath(p, src))
                zi = zipfile.ZipInfo.from_file(p, arc)
                zi.compress_type = zipfile.ZIP_STORED
                if os.access(p, os.X_OK):
                    zi.external_attr = (stat.S_IFREG | 0o755) << 16
                with open(p, "rb") as fh, z.open(zi, "w", force_zip64=True) as w:
                    shutil.copyfileobj(fh, w, 1 << 20)

if __name__ == "__main__":
    main()
