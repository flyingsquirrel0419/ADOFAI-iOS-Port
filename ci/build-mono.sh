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
export CFLAGS="-mmacosx-version-min=$MACVER -isysroot $SDK -g -Os"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-mmacosx-version-min=$MACVER -isysroot $SDK"
export MACSDKOPTIONS="$CFLAGS"

cd "$SRC"
rm -f config.status eglib/config.status libgc/config.status

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
