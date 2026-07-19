#!/usr/bin/env bash
# Stages the iOS-simulator Dawn build as an xcframework for the SwiftPM
# backend toggle in ios/nitro_webgpu/Package.swift.
set -euo pipefail
DAWN_SRC="${NITRO_WEBGPU_DAWN_SRC:-$HOME/.cache/nitro_webgpu/dawn-src}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="$DAWN_SRC/out-ios-sim/src/dawn/native/libwebgpu_dawn.dylib"
[[ -f "$DYLIB" ]] || { echo "error: $DYLIB not found — build Dawn for the iOS simulator first (see doc/DAWN_MIGRATION.md)" >&2; exit 1; }

INC="$REPO_ROOT/src/third_party/dawn/include"
mkdir -p "$INC/webgpu" "$INC/dawn"
cp "$DAWN_SRC/include/webgpu/webgpu.h" "$INC/webgpu/"
cp "$DAWN_SRC/out-ios-sim/gen/include/dawn/webgpu.h" "$INC/dawn/"

FRAMEWORKS="$REPO_ROOT/ios/nitro_webgpu/Frameworks"
rm -rf "$FRAMEWORKS/webgpu_dawn.xcframework"
xcodebuild -create-xcframework \
  -library "$DYLIB" \
  -output "$FRAMEWORKS/webgpu_dawn.xcframework" >/dev/null
echo "[dawn] staged ios-simulator: $FRAMEWORKS/webgpu_dawn.xcframework"
