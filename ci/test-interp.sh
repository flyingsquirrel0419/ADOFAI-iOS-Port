#!/bin/bash
# 1단계 검증: JIT 권한이 없는 프로세스(iOS와 같은 조건)에서 Mono가 MONO_AOT_MODE_INTERP로 도는지.
#   ci/test-interp.sh <mono 설치 prefix> <작업 디렉터리>
# 결과 요약은 <작업 디렉터리>/summary.md (CI에서는 Step Summary로도 출력)
set -uo pipefail

PREFIX=$(cd "$1" && pwd)
W=$2; mkdir -p "$W"; W=$(cd "$W" && pwd)
HERE=$(cd "$(dirname "$0")/.." && pwd)
SUM="$W/summary.md"
: > "$SUM"
log() { echo "$*" | tee -a "$SUM"; }

# 게임 런타임은 Boehm GC(libmonobdwgc) → 같은 GC 바이너리가 있으면 그것으로
MONO="$PREFIX/bin/mono"
for c in mono-bdwgc mono-boehm; do [ -x "$PREFIX/bin/$c" ] && MONO="$PREFIX/bin/$c"; done
PROFILE_DIR="$PREFIX/lib/mono/4.5"

log "## Mono 인터프리터 검증"
log ""
log "- runtime: \`$("$MONO" --version | head -1)\`"
log "- binary: \`$(basename "$MONO")\`, bin/: $(ls "$PREFIX/bin" | grep -E '^mono' | tr '\n' ' ')"
log "- profiles: $(ls "$PREFIX/lib/mono" | tr '\n' ' ')"
log "- runtime libs: $(ls "$PREFIX/lib" | grep -E 'libmono.*dylib$' | tr '\n' ' ')"
log ""

# Unity 빌드의 런타임은 클래스 라이브러리를 lib/mono/net_4_x-macos 에서 찾는다 (Unity 패키징 스크립트가 만드는 폴더).
# make install 은 4.5/ 에 unityjit-macos 프로필(게임과 같은 프로필)을 넣으므로 그리로 잇는다.
[ -e "$PREFIX/lib/mono/net_4_x-macos" ] || ln -s 4.5 "$PREFIX/lib/mono/net_4_x-macos"

# --- 진단: 클래스 라이브러리 로딩 ---
echo "::group::corlib 진단"
ls -la "$PROFILE_DIR"/mscorlib* "$PROFILE_DIR"/mcs.exe 2>&1
MONO_LOG_LEVEL=debug MONO_LOG_MASK=asm,dll,cfg "$PREFIX/bin/mono" "$PROFILE_DIR/mcs.exe" --version 2>&1 | grep -viE "^Mono: DllImport|probing" | tail -40
MONO_LOG_LEVEL=debug MONO_LOG_MASK=asm "$MONO" "$PROFILE_DIR/mcs.exe" --version 2>&1 | tail -15
echo "::endgroup::"

# --- 테스트 빌드 ---
cd "$W"
cp "$HERE/tests/interp/Test.cs" .
xcrun clang -arch arm64 -dynamiclib -o libinterptest.dylib "$HERE/tests/interp/interptest.c"
CSC="$PREFIX/bin/mcs"; [ -x "$CSC" ] || CSC="$PREFIX/bin/csc"
"$CSC" -nologo -optimize+ -r:System.Core.dll -out:Test.exe Test.cs || { log "**테스트 컴파일 실패**"; exit 1; }
export DYLD_LIBRARY_PATH="$W"

# --- JIT 금지: iOS 처럼 실행 중 코드 생성을 막는 인터포저 (tests/interp/nojit.c) ---
xcrun clang -arch arm64 -dynamiclib -o libnojit.dylib "$HERE/tests/interp/nojit.c"
cat > mono-nojit <<EOS
#!/bin/bash
DYLD_INSERT_LIBRARIES="$W/libnojit.dylib" exec "$MONO" "\$@"
EOS
chmod +x mono-nojit

run() {  # run <이름> <기대> <명령...>
    local name=$1 expect=$2; shift 2
    echo "::group::$name"
    local out; out=$("$@" 2>&1); local rc=$?
    echo "$out" | tail -80
    echo "::endgroup::"
    local res; res=$(echo "$out" | grep -E '^RESULT' | tail -1)
    local bench; bench=$(echo "$out" | grep -E '^BENCH' | tail -1)
    local fails; fails=$(echo "$out" | grep -E '^FAIL' | head -8 | sed 's/^/    - /')
    log "### $name"
    log "- 기대: $expect / 종료코드: $rc / ${res:-RESULT 없음 (크래시?)}"
    [ -n "$bench" ] && log "- \`$bench\`"
    [ -n "$fails" ] && log "$fails"
    if [ -z "$res" ]; then log '```'; echo "$out" | tail -15 >> "$SUM"; log '```'; fi
    log ""
}

# A. 기준선: 일반 JIT
run "A. JIT (기준선)" "전부 통과" "$MONO" Test.exe all

# B. 음성 대조: JIT 금지 + JIT 모드 -> 반드시 실패해야 함 (실패해야 강제가 걸렸다는 증거)
run "B. JIT 금지 + JIT 모드 (음성 대조)" "크래시/실패" ./mono-nojit Test.exe basic

# C. JIT 금지 + 순수 인터프리터(AOT 이미지 없음) → 트램폴린을 실행 중 생성하려다 실패할 것으로 예상
run "C. JIT 금지 + --interpreter (AOT 없음)" "실패 예상" ./mono-nojit --interpreter Test.exe basic

# --- AOT(interp) 이미지 생성: 클래스 라이브러리 ---
echo "::group::AOT --aot=interp"
# mscorlib: full,interp (Xamarin.iOS 인터프리터 방식: 트램폴린 포함 + 기본 라이브러리는 네이티브 AOT 코드)
( cd "$PROFILE_DIR" && "$MONO" --aot=full,interp mscorlib.dll ) 2>&1 | tail -3
# 그 밖의 어셈블리 (게임 DLL 역할): interp 만 (래퍼만; 코드는 인터프리터)
for a in System System.Core; do ( cd "$PROFILE_DIR" && "$MONO" --aot=interp "$a.dll" ) 2>&1 | tail -3; done
"$MONO" --aot=interp Test.exe 2>&1 | tail -3
echo "::endgroup::"
log "- AOT 이미지: $(cd "$PROFILE_DIR" && ls -la mscorlib.dll.dylib System.dll.dylib System.Core.dll.dylib 2>/dev/null | awk '{print $9" "$5}' | tr '\n' ' ') $(ls Test.exe.dylib 2>/dev/null)"
log "- 크기: $(cd "$PROFILE_DIR" && du -ch *.dll.dylib 2>/dev/null | tail -1)"
log ""

# D. 핵심: JIT 금지 + full-aot-interp (게임 어셈블리 역할인 Test.exe도 AOT)
run "D. JIT 금지 + --full-aot-interp (Test.exe AOT 있음)" "전부 통과" ./mono-nojit --full-aot-interp Test.exe all

# E. 게임 DLL을 AOT 못 하는 경우를 흉내: Test.exe AOT 이미지 치우고
mv Test.exe.dylib Test.exe.dylib.off 2>/dev/null
run "E1. JIT 금지 + --full-aot-interp (Test.exe AOT 없음) basic" "통과하면 게임 DLL AOT 불필요" ./mono-nojit --full-aot-interp Test.exe basic
run "E2. 같은 조건 callback" "reverse P/Invoke 래퍼 필요 여부" ./mono-nojit --full-aot-interp Test.exe callback
mv Test.exe.dylib.off Test.exe.dylib 2>/dev/null

# H. 원인 가르기: JIT 를 허용한 상태에서도 인터프리터가 인자를 깨뜨리는가?
#    (깨지면 이 Mono 포크의 인터프리터 자체 문제, 안 깨지면 JIT 금지/AOT 조합 문제)
run "H1. JIT 허용 + --interpreter (순수 인터프리터)" "진단" "$MONO" --interpreter Test.exe all
run "H2. JIT 허용 + --full-aot-interp" "진단" "$MONO" --full-aot-interp Test.exe all
run "H3. JIT 허용 + --hybrid-aot (AOT+JIT, 인터프리터 없음)" "진단" "$MONO" --hybrid-aot Test.exe basic

# G. mscorlib 도 인터프리터로: 빈 AOT 프로필 + profile-only -> 메서드 코드 없이 트램폴린/래퍼만.
#    인터프리터 -> AOT 코드 직접 호출(do_jit_call -> gsharedvt_out_sig) 경로가 없어진다 (D 에서 인자가 깨지는 경로)
printf 'AOTPROFILE' > empty.aotprofile
printf '\x00\x00\x01\x00\x00\x00\x00\x00\x00' >> empty.aotprofile   # version 0x00010000 (LE), RECORD_NONE, id 0
cp "$PROFILE_DIR/mscorlib.dll.dylib" mscorlib.full.dylib
echo "::group::AOT mscorlib profile-only"
( cd "$PROFILE_DIR" && "$MONO" --aot=full,interp,profile="$W/empty.aotprofile",profile-only mscorlib.dll ) 2>&1 | tail -5
echo "::endgroup::"
log "- profile-only mscorlib AOT: $(ls -la "$PROFILE_DIR/mscorlib.dll.dylib" | awk '{print $5}') bytes (full: $(ls -la mscorlib.full.dylib | awk '{print $5}'))"
run "G1. JIT 금지 + mscorlib profile-only (전부 인터프리터)" "전부 통과" ./mono-nojit --full-aot-interp Test.exe all
mv Test.exe.dylib Test.exe.dylib.off 2>/dev/null
run "G2. 같은 조건, Test.exe AOT 없음 (게임 DLL 역할)" "전부 통과" ./mono-nojit --full-aot-interp Test.exe all
mv Test.exe.dylib.off Test.exe.dylib 2>/dev/null
cp mscorlib.full.dylib "$PROFILE_DIR/mscorlib.dll.dylib"

# F. 성능: JIT 대비 인터프리터
run "F1. bench JIT" "-" "$MONO" Test.exe bench
run "F2. bench interp (JIT 금지)" "-" ./mono-nojit --full-aot-interp Test.exe bench

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$SUM" >> "$GITHUB_STEP_SUMMARY"
cat "$SUM"
exit 0
