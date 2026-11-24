#!/bin/bash
# 게임에 들어 있는 것과 같은 커밋의 Unity Mono(unity-mono@9d7c9afd)를 macOS arm64로 빌드.
# Unity의 external/buildscripts/build.pl (macOS desktop arm64 분기)의 configure 인자를 그대로 따르되,
# 공개되지 않은 Unity 내부 Stevedore 의존성 대신 Homebrew 도구를 사용한다.
#
#   ci/build-mono.sh <mono 소스 디렉터리> <설치 prefix>
set -euo pipefail

SRC=$(cd "$1" && pwd)
PREFIX=$2
mkdir -p "$PREFIX"
PREFIX=$(cd "$PREFIX" && pwd)

JOBS=$(sysctl -n hw.ncpu)
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACVER=11.0
TRIPLE=aarch64-apple-darwinmacos12.2.0

# 부트스트랩용 C# 컴파일러 (Homebrew mono)
BOOT_MCS=$(command -v mcs)
echo ">>> bootstrap mcs: $BOOT_MCS"; mcs --version

export CC="$(xcrun -f clang) -arch arm64"
export CXX="$(xcrun -f clang++) -arch arm64"
# 최신 clang(16+)에서 오류로 승격된 경고들은 Unity 툴체인(Xcode 12)에서는 경고였다 -> 경고로 되돌림
COMPAT="-Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=implicit-int"
#  - 새 SDK 의 stdbool.h 는 bool 을 _Bool 매크로로 정의 -> icall 시그니처 매크로 이름이 ICALL_SIG_TYPE__Bool 로 펼쳐짐
COMPAT="$COMPAT -DICALL_SIG_TYPE__Bool=ICALL_SIG_TYPE_bool"
OPT=${MONO_OPT:--Os}   # 인터프리터가 최신 clang 최적화에 깨지는지 가르기 위해 바꿀 수 있게 (MONO_OPT=-O0)
echo ">>> optimization: $OPT"
export CFLAGS="-mmacosx-version-min=$MACVER -isysroot $SDK -g $OPT $COMPAT"
export CXXFLAGS="-mmacosx-version-min=$MACVER -isysroot $SDK -g $OPT"
export CPPFLAGS="-mmacosx-version-min=$MACVER -isysroot $SDK"
export MACSDKOPTIONS="$CFLAGS"

cd "$SRC"
rm -f config.status eglib/config.status libgc/config.status

# 최신 Xcode SDK 호환 (Unity 는 SDK 11 로 빌드). 생성되는 기계어는 같다 - 이름만 다른 경우만 고친다.
#  - objc/message.h: 일반 C 에서도 struct objc_super 의 멤버가 super_class 로 바뀜 (같은 위치)
sed -i '' 's/super\.class = nsobject;/super.super_class = nsobject;/' mono/utils/mono-threads-mach-helper.c
grep -n "super_class = nsobject" mono/utils/mono-threads-mach-helper.c

# build.pl 과 같은 인자 (+ boringssl 서브모듈을 받지 않으므로 btls 끔)
./autogen.sh \
  --prefix="$PREFIX" \
  --build=$TRIPLE --host=$TRIPLE \
  --with-glib=embedded \
  --disable-nls \
  --with-mcs-docs=no \
  --enable-no-threads-discovery=yes \
  --enable-ignore-dynamic-loading=yes \
  --enable-dont-register-main-static-data=yes \
  --enable-thread-local-alloc=no \
  --enable-unity-define=yes \
  --with-unityjit=yes \
  --with-unityaot=yes \
  --with-monotouch=no \
  --with-libgdiplus=libgdiplus.dylib \
  --enable-minimal=com,shared_perfcounters \
  --disable-parallel-mark \
  --enable-verify-defines \
  --disable-btls

make -j"$JOBS" EXTERNAL_MCS="$BOOT_MCS"
make install

echo ">>> installed:"
ls -la "$PREFIX/bin" "$PREFIX/lib" | head -60
ls "$PREFIX/lib/mono" || true
"$PREFIX/bin/mono" --version
