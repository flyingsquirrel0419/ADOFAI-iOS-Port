#!/bin/bash
# libADOFAIShim.dylib (iOS arm64) 빌드. macOS + Xcode 필요 (GitHub Actions macos 러너).
#   ci/build-shim.sh <출력 디렉터리>
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$HERE/build/shim}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos -f clang)
echo ">>> iOS SDK: $SDK"

"$CLANG" -target arm64-apple-ios16.0 -isysroot "$SDK" -dynamiclib -fobjc-arc -O2 -g \
  -Wall -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations -Wno-objc-method-access \
  -fvisibility=default \
  -install_name @rpath/libADOFAIShim.dylib -compatibility_version 1.0.0 -current_version 1.0.0 \
  -framework Foundation -framework UIKit -framework QuartzCore -framework GameController -framework AVFoundation \
  -framework AudioToolbox -framework CoreGraphics -framework CoreVideo -framework Security -framework Metal \
  -framework CoreFoundation \
  -Wl,-reexport_framework,Foundation -Wl,-reexport_framework,CoreGraphics -Wl,-reexport_framework,CoreVideo \
  -Wl,-reexport_framework,Security -Wl,-reexport_framework,AVFoundation \
  "$HERE/shim/ShimCore.m" "$HERE/shim/AppKit.m" "$HERE/shim/Audio.m" "$HERE/shim/DisplayLink.m" \
  "$HERE/shim/MonoInterp.c" "$HERE/shim/Stubs.c" \
  -o "$OUT/libADOFAIShim.dylib"

xcrun nm -gU "$OUT/libADOFAIShim.dylib" | awk '{print $3}' | sort -u > "$OUT/libADOFAIShim.exports.txt"
echo ">>> exports: $(wc -l < "$OUT/libADOFAIShim.exports.txt")"
xcrun otool -L "$OUT/libADOFAIShim.dylib"
