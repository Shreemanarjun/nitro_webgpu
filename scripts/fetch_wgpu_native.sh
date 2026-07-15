#!/usr/bin/env bash
# Fetches prebuilt wgpu-native static libraries into src/third_party/wgpu_native/.
#
# Usage:
#   scripts/fetch_wgpu_native.sh                     # all targets for this host OS
#   scripts/fetch_wgpu_native.sh --targets macos-aarch64,linux-x86_64
#   scripts/fetch_wgpu_native.sh --all               # every supported target
#   scripts/fetch_wgpu_native.sh --force             # re-download even if present
#   scripts/fetch_wgpu_native.sh --update-checksums  # rewrite scripts/wgpu_native.sha256
#
# On a macOS host this also produces:
#   macos/Frameworks/libwgpu_native.a      (universal, lipo'd)
#   ios/Frameworks/wgpu_native.xcframework (device + universal simulator)
set -euo pipefail

WGPU_NATIVE_VERSION="v29.0.1.1"
ALL_TARGETS=(
  macos-aarch64 macos-x86_64
  ios-aarch64 ios-aarch64-simulator ios-x86_64-simulator
  android-aarch64 android-armv7 android-x86_64
  windows-x86_64-msvc
  linux-x86_64 linux-aarch64
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEST_ROOT="$ROOT_DIR/src/third_party/wgpu_native"
SHA_FILE="$SCRIPT_DIR/wgpu_native.sha256"
BASE_URL="https://github.com/gfx-rs/wgpu-native/releases/download/$WGPU_NATIVE_VERSION"

FORCE=0
UPDATE_CHECKSUMS=0
TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets) IFS=',' read -r -a TARGETS <<<"$2"; shift 2 ;;
    --all) TARGETS=("${ALL_TARGETS[@]}"); shift ;;
    --force) FORCE=1; shift ;;
    --update-checksums) UPDATE_CHECKSUMS=1; FORCE=1; shift ;;
    --version) WGPU_NATIVE_VERSION="$2"; BASE_URL="https://github.com/gfx-rs/wgpu-native/releases/download/$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Default: the targets this host OS can build for.
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  case "$(uname -s)" in
    Darwin) TARGETS=(macos-aarch64 macos-x86_64 ios-aarch64 ios-aarch64-simulator ios-x86_64-simulator android-aarch64 android-armv7 android-x86_64) ;;
    Linux)  TARGETS=(linux-x86_64 linux-aarch64 android-aarch64 android-armv7 android-x86_64) ;;
    MINGW*|MSYS*|CYGWIN*) TARGETS=(windows-x86_64-msvc) ;;
    *) echo "unrecognized host OS; pass --targets explicitly" >&2; exit 2 ;;
  esac
fi

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

mkdir -p "$DEST_ROOT"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[[ $UPDATE_CHECKSUMS -eq 1 ]] && : >"$SHA_FILE.new"

fetched_any=0
for target in "${TARGETS[@]}"; do
  zip_name="wgpu-$target-release.zip"
  dest="$DEST_ROOT/$target"
  stamp="$dest/.version"

  if [[ $FORCE -eq 0 && -f "$stamp" && "$(cat "$stamp")" == "$WGPU_NATIVE_VERSION" ]]; then
    echo "[wgpu] $target: up to date ($WGPU_NATIVE_VERSION)"
    continue
  fi

  echo "[wgpu] fetching $zip_name ..."
  curl -fSL --retry 3 -o "$TMP_DIR/$zip_name" "$BASE_URL/$zip_name"

  actual="$(sha256 "$TMP_DIR/$zip_name")"
  if [[ $UPDATE_CHECKSUMS -eq 1 ]]; then
    printf '%s  %s\n' "$actual" "$zip_name" >>"$SHA_FILE.new"
  else
    expected="$(grep " $zip_name\$" "$SHA_FILE" | awk '{print $1}' || true)"
    if [[ -z "$expected" ]]; then
      echo "[wgpu] ERROR: no pinned checksum for $zip_name in $SHA_FILE" >&2; exit 1
    fi
    if [[ "$actual" != "$expected" ]]; then
      echo "[wgpu] ERROR: checksum mismatch for $zip_name" >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      exit 1
    fi
  fi

  rm -rf "$dest"
  mkdir -p "$dest"
  unzip -oq "$TMP_DIR/$zip_name" -d "$dest"
  echo "$WGPU_NATIVE_VERSION" >"$stamp"
  fetched_any=1
done

if [[ $UPDATE_CHECKSUMS -eq 1 ]]; then
  {
    echo "# sha256 pins for wgpu-native $WGPU_NATIVE_VERSION release archives."
    echo "# Regenerate with: scripts/fetch_wgpu_native.sh --update-checksums"
    cat "$SHA_FILE.new"
  } >"$SHA_FILE"
  rm -f "$SHA_FILE.new"
  echo "[wgpu] wrote $SHA_FILE"
fi

# Shared headers: identical across targets; copy from any fetched one.
for target in "${TARGETS[@]}"; do
  if [[ -d "$DEST_ROOT/$target/include/webgpu" ]]; then
    rm -rf "$DEST_ROOT/include"
    mkdir -p "$DEST_ROOT/include"
    cp -R "$DEST_ROOT/$target/include/webgpu" "$DEST_ROOT/include/webgpu"
    break
  fi
done
echo "$WGPU_NATIVE_VERSION" >"$DEST_ROOT/VERSION"

# Apple packaging (host must be macOS). xcframeworks live inside the SwiftPM
# package directories so they can be SPM binary targets AND podspec
# vendored_frameworks at the same time.
if [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -f "$DEST_ROOT/macos-aarch64/lib/libwgpu_native.a" && -f "$DEST_ROOT/macos-x86_64/lib/libwgpu_native.a" ]]; then
    lipo -create \
      "$DEST_ROOT/macos-aarch64/lib/libwgpu_native.a" \
      "$DEST_ROOT/macos-x86_64/lib/libwgpu_native.a" \
      -output "$TMP_DIR/libwgpu_native_macos.a"
    rm -rf "$ROOT_DIR/macos/nitro_webgpu/Frameworks/wgpu_native.xcframework"
    mkdir -p "$ROOT_DIR/macos/nitro_webgpu/Frameworks"
    xcodebuild -create-xcframework \
      -library "$TMP_DIR/libwgpu_native_macos.a" \
      -output "$ROOT_DIR/macos/nitro_webgpu/Frameworks/wgpu_native.xcframework" >/dev/null
    echo "[wgpu] wrote macos/nitro_webgpu/Frameworks/wgpu_native.xcframework (universal)"
  fi
  if [[ -f "$DEST_ROOT/ios-aarch64/lib/libwgpu_native.a" \
     && -f "$DEST_ROOT/ios-aarch64-simulator/lib/libwgpu_native.a" \
     && -f "$DEST_ROOT/ios-x86_64-simulator/lib/libwgpu_native.a" ]]; then
    lipo -create \
      "$DEST_ROOT/ios-aarch64-simulator/lib/libwgpu_native.a" \
      "$DEST_ROOT/ios-x86_64-simulator/lib/libwgpu_native.a" \
      -output "$TMP_DIR/libwgpu_native_sim.a"
    rm -rf "$ROOT_DIR/ios/nitro_webgpu/Frameworks/wgpu_native.xcframework"
    mkdir -p "$ROOT_DIR/ios/nitro_webgpu/Frameworks"
    xcodebuild -create-xcframework \
      -library "$DEST_ROOT/ios-aarch64/lib/libwgpu_native.a" \
      -library "$TMP_DIR/libwgpu_native_sim.a" \
      -output "$ROOT_DIR/ios/nitro_webgpu/Frameworks/wgpu_native.xcframework" >/dev/null
    echo "[wgpu] wrote ios/nitro_webgpu/Frameworks/wgpu_native.xcframework"
  fi
fi

echo "[wgpu] done ($WGPU_NATIVE_VERSION)"
