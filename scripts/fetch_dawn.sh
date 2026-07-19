#!/usr/bin/env bash
# Vendors prebuilt Dawn from this repo's `dawn-v*` GitHub releases (built by
# .github/workflows/dawn_prebuilt.yml) into the staged layout the backend
# switch expects — the no-local-build alternative to the stage_dawn_*.sh
# scripts.
#
#   scripts/fetch_dawn.sh --version dawn-v1 --targets macos-aarch64,android-aarch64
set -euo pipefail

REPO="${NITRO_WEBGPU_DAWN_REPO:-Shreemanarjun/nitro_webgpu}"
VERSION="dawn-v1"
TARGETS="macos-aarch64,android-aarch64"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    *) echo "usage: $0 [--version dawn-vN] [--targets a,b,c]" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/src/third_party/dawn"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

IFS=',' read -ra LIST <<<"$TARGETS"
for target in "${LIST[@]}"; do
  zip="dawn-$target.zip"
  echo "[dawn] fetching $zip ($VERSION)"
  curl -fSL --retry 3 -o "$TMP/$zip" \
    "https://github.com/$REPO/releases/download/$VERSION/$zip"
  unzip -qo "$TMP/$zip" -d "$TMP"
  mkdir -p "$DEST/$target"
  rm -rf "$DEST/$target/lib"
  cp -R "$TMP/dawn-$target/lib" "$DEST/$target/lib"
  mkdir -p "$DEST/include"
  cp -R "$TMP/dawn-$target/include/." "$DEST/include/"
  if [[ "$target" == macos-* || "$target" == ios-* ]]; then
    case "$target" in
      macos-*) FRAMEWORKS="$REPO_ROOT/macos/nitro_webgpu/Frameworks" ;;
      ios-*)   FRAMEWORKS="$REPO_ROOT/ios/nitro_webgpu/Frameworks" ;;
    esac
    rm -rf "$FRAMEWORKS/webgpu_dawn.xcframework"
    xcodebuild -create-xcframework \
      -library "$DEST/$target/lib/libwebgpu_dawn.dylib" \
      -output "$FRAMEWORKS/webgpu_dawn.xcframework" >/dev/null
  fi
  if [[ "$target" == android-* ]]; then
    abi="arm64-v8a"
    [[ "$target" == *armv7* ]] && abi="armeabi-v7a"
    [[ "$target" == *x86_64* ]] && abi="x86_64"
    mkdir -p "$REPO_ROOT/android/src/main/jniLibs/$abi"
    cp "$DEST/$target/lib/libwebgpu_dawn.so" \
       "$REPO_ROOT/android/src/main/jniLibs/$abi/"
  fi
done
echo "[dawn] done ($VERSION)"
