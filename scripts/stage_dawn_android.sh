#!/usr/bin/env bash
# Stages the NDK-built Dawn for Android arm64: headers shared with the macOS
# staging, the .so for CMake linking AND gradle jniLibs packaging.
set -euo pipefail
DAWN_SRC="${NITRO_WEBGPU_DAWN_SRC:-$HOME/.cache/nitro_webgpu/dawn-src}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SO="$DAWN_SRC/out-android-arm64/src/dawn/native/libwebgpu_dawn.so"
[[ -f "$SO" ]] || { echo "error: $SO not found — build Dawn for Android first (see docs/DAWN_MIGRATION.md)" >&2; exit 1; }

INC="$REPO_ROOT/src/third_party/dawn/include"
mkdir -p "$INC/webgpu" "$INC/dawn"
cp "$DAWN_SRC/include/webgpu/webgpu.h" "$INC/webgpu/"
cp "$DAWN_SRC/out-android-arm64/gen/include/dawn/webgpu.h" "$INC/dawn/"

LIBDIR="$REPO_ROOT/src/third_party/dawn/android-aarch64/lib"
mkdir -p "$LIBDIR"
cp "$SO" "$LIBDIR/"
JNI="$REPO_ROOT/android/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI"
cp "$SO" "$JNI/"
echo "[dawn] staged android-aarch64: $LIBDIR + jniLibs"
