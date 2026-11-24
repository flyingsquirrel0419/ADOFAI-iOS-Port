#!/bin/bash
# mscorlib 의 인터프리터용 AOT 이미지를 iOS dylib (libADOFAIAot.dylib) 로 만든다.
#   ci/build-aot-ios.sh <mono 설치 prefix> <출력 디렉터리>
#
# 게임 런타임(libmonobdwgc-2.0.dylib)이 AOT 이미지를 받아들이는 조건 (mono/mini/aot-runtime.c):
#   - 어셈블리 GUID 일치      -> 여기서 쓴 mscorlib.dll 을 게임의 것 대신 넣는다 (make_app.py)
#   - runtime_version 일치   -> "6.13.0 (explicit/9d7c9afd)". mono 실행 파일은 main.c 에서 빌드 날짜를 붙이므로
#                              빌드 날짜를 넣지 않는 임베딩 드라이버(mono_main 만 부름)로 컴파일한다
#   - GC 이름 일치 (boehm)    -> libmonobdwgc 로 컴파일
#   - --aot=interp            -> 인터프리터 트램폴린 포함
# static 으로 만들어 shim 이 mono_aot_register_module 로 등록한다 (파일 경로 검색 불필요).
set -euo pipefail
PREFIX=$(cd "$1" && pwd)
OUT=$2; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d)

LIB=$(ls "$PREFIX"/lib/libmonobdwgc-2.0.dylib "$PREFIX"/lib/libmonoboehm-2.0.dylib 2>/dev/null | head -1 || true)
[ -n "$LIB" ] || { echo "no Boehm runtime dylib in $PREFIX/lib:"; ls "$PREFIX/lib"; exit 1; }
echo ">>> runtime: $LIB"

# 게임이 쓰는 클래스 라이브러리 프로필 (Unity 맥 플레이어: unityjit-macos). 없으면 4.5
PROF=""
for p in unityjit-macos unityjit 4.5; do [ -f "$PREFIX/lib/mono/$p/mscorlib.dll" ] && { PROF=$p; break; }; done
[ -n "$PROF" ] || { echo "no mscorlib.dll"; ls "$PREFIX/lib/mono"; exit 1; }
echo ">>> profile: $PROF"
for p in "$PREFIX"/lib/mono/*/mscorlib.dll; do echo "    $(stat -f %z "$p") $p"; done

cat > "$W/aotdrv.c" <<'EOF'
// mono_main 만 부르는 임베딩 드라이버: mono_build_date 를 설정하지 않아 runtime_version 이 게임 런타임과 같아진다
extern int mono_main(int argc, char *argv[]);
extern void mono_set_dirs(const char *assembly_dir, const char *config_dir);
int main(int argc, char *argv[]) { return mono_main(argc, argv); }
EOF
xcrun clang -arch arm64 "$W/aotdrv.c" -o "$W/aotdrv" "$LIB" -Wl,-rpath,"$(dirname "$LIB")"
cp "$PREFIX/lib/mono/$PROF/mscorlib.dll" "$W/"

cd "$W"
echo ">>> AOT mscorlib (interp,static,asmonly)"
MONO_PATH="$PREFIX/lib/mono/$PROF" ./aotdrv --aot=interp,static,asmonly,outfile=mscorlib.s mscorlib.dll 2>&1 | tail -20
ls -la mscorlib.s
echo ">>> runtime_version / gc in image:"
grep -a -m3 -E '6\.13\.0 \(|"boehm"|boehm' mscorlib.s || true

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" -c mscorlib.s -o mscorlib.o
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" -dynamiclib mscorlib.o \
  -install_name @rpath/libADOFAIAot.dylib -Wl,-undefined,dynamic_lookup -o "$OUT/libADOFAIAot.dylib"
cp mscorlib.dll "$OUT/mscorlib.dll"
xcrun nm -gU "$OUT/libADOFAIAot.dylib" | grep -i "aot_module" || { echo "no mono_aot_module_*_info symbol"; exit 1; }
xcrun nm -u "$OUT/libADOFAIAot.dylib" | head -20
ls -la "$OUT"
