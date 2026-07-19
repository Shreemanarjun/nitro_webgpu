#!/usr/bin/env bash
# Stages NDK-built Dawn for Android: headers shared with the desktop
# staging, stripped .so per ABI for CMake linking AND gradle jniLibs
# packaging. Builds live at $DAWN_SRC/out-android-{arm64,armeabi-v7a,x86_64}
# (arm64's build dir is out-android-arm64).
set -euo pipefail
DAWN_SRC="${NITRO_WEBGPU_DAWN_SRC:-$HOME/.cache/nitro_webgpu/dawn-src}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/30.0.14904198}"
STRIP="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"

INC="$REPO_ROOT/src/third_party/dawn/include"
mkdir -p "$INC/webgpu" "$INC/dawn"
cp "$DAWN_SRC/include/webgpu/webgpu.h" "$INC/webgpu/"

staged=0
stage_abi() {
  local out_dir="$1" target="$2" abi="$3"
  local so="$DAWN_SRC/$out_dir/src/dawn/native/libwebgpu_dawn.so"
  [[ -f "$so" ]] || return 0
  cp "$DAWN_SRC/$out_dir/gen/include/dawn/webgpu.h" "$INC/dawn/"
  local libdir="$REPO_ROOT/src/third_party/dawn/$target/lib"
  local jni="$REPO_ROOT/android/src/main/jniLibs/$abi"
  mkdir -p "$libdir" "$jni"
  "$STRIP" --strip-unneeded -o "$libdir/libwebgpu_dawn.so" "$so"
  cp "$libdir/libwebgpu_dawn.so" "$jni/"
  echo "[dawn] staged $target ($(du -h "$libdir/libwebgpu_dawn.so" | cut -f1))"
  staged=1
}
stage_abi out-android-arm64        android-aarch64 arm64-v8a
stage_abi out-android-armeabi-v7a  android-armv7   armeabi-v7a
stage_abi out-android-x86_64       android-x86_64  x86_64
[[ $staged -eq 1 ]] || { echo "error: no Android Dawn builds found" >&2; exit 1; }
