#!/usr/bin/env bash
# Stages a locally-built Dawn (see doc/DAWN_MIGRATION.md) for the macOS
# backend switch: headers into src/third_party/dawn/include and the
# monolithic dylib wrapped as an xcframework the podspec can vendor.
#
#   NITRO_WEBGPU_BACKEND=dawn flutter run -d macos
set -euo pipefail

DAWN_SRC="${NITRO_WEBGPU_DAWN_SRC:-$HOME/.cache/nitro_webgpu/dawn-src}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="$DAWN_SRC/out/src/dawn/native/libwebgpu_dawn.dylib"

[[ -f "$DYLIB" ]] || {
  echo "error: $DYLIB not found — build Dawn first:" >&2
  echo "  cmake -S $DAWN_SRC -B $DAWN_SRC/out -DCMAKE_BUILD_TYPE=Release \\" >&2
  echo "    -DDAWN_FETCH_DEPENDENCIES=ON -DDAWN_BUILD_MONOLITHIC_LIBRARY=SHARED" >&2
  echo "  cmake --build $DAWN_SRC/out --target webgpu_dawn -j 10" >&2
  exit 1
}

INC="$REPO_ROOT/src/third_party/dawn/include"
rm -rf "$INC"
mkdir -p "$INC/webgpu" "$INC/dawn"
cp "$DAWN_SRC/include/webgpu/webgpu.h" "$INC/webgpu/"
cp "$DAWN_SRC/out/gen/include/dawn/webgpu.h" "$INC/dawn/"

FRAMEWORKS="$REPO_ROOT/macos/nitro_webgpu/Frameworks"
rm -rf "$FRAMEWORKS/webgpu_dawn.xcframework"
xcodebuild -create-xcframework \
  -library "$DYLIB" \
  -output "$FRAMEWORKS/webgpu_dawn.xcframework" >/dev/null
echo "[dawn] staged: $INC + $FRAMEWORKS/webgpu_dawn.xcframework"
